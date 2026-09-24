package com.aliothmoon.maafw.proot

import android.content.Context
import timber.log.Timber
import java.io.File

/**
 * App 资产 `alas/` 对 rootfs `/opt/alas` 的运行时覆盖
 *
 * 两份职责：
 * - wrapper/runner/seed/alasaos_update.sh 随 App 版本演进，改它们不必重烘焙 rootfs
 *   （rootfs.tar.xz 里那份只是兜底；每次启动都被这里盖成 App 当前版本）
 * - 热更新 `git reset --hard` 会把上游跟踪文件打回原版：补丁必须在 UPDATED 后重放
 *
 * 覆盖方式是按字节比对的幂等拷贝；STALE_FILES 在拷贝后删除——断代更名
 * （如 maaal→alasaos）留下的旧名文件只删不盖，防旧码被误加载。
 *
 * ── 按上游 flavor 分流（2026-09-24 新增，**关键**）──────────────────────────
 * 本仓 `assets/alas/patches/module/**` 是 **ALAS 时代的「整文件副本」补丁**
 * （connection.py 1267 行 / screenshot.py / control.py / app_control.py / base.py …），
 * 它们**对着 ALAS 上游写**。整层盖到 AzurPilot 上会回退上游实现、引用不存在的 API
 * ——等于把上游改坏。构建侧（build-rootfs.sh）已按 flavor 分流，App 侧同样必须分流，
 * 否则每次启动都会把上游改坏。
 *
 * 按 `/opt/alas/BUILD_MANIFEST` 的 `upstream_flavor` 分流：
 * - `alas`        ：维持旧行为（整层覆盖 + OCR shim + ALAS 素材）
 * - `azurpilot*`  ：**只铺我方纯新增的资产**（wrapper / runner / seeds / alasaos.py）；
 *                   ALAS 整文件补丁、OCR shim、ALAS 专用素材一律不铺。
 *                   桥接接线由构建期 `rootfs/patches/azurpilot-android.patch` 注入。
 */
class AlasOverlay(private val context: Context) {

    data class Result(val copied: Int, val skipped: Int, val failed: Int, val flavor: String)

    /**
     * 读 `/opt/alas/BUILD_MANIFEST` 的 `upstream_flavor`。
     * 读不到就返回 "unknown" —— 此时走 **azurpilot 的保守策略**（宁可不铺，
     * 也不能把上游改坏）。
     */
    private fun readUpstreamFlavor(alasDir: File): String = runCatching {
        val m = File(alasDir, "BUILD_MANIFEST")
        if (!m.isFile) return@runCatching "unknown"
        Regex(""""upstream_flavor"\s*:\s*"([^"]+)"""").find(m.readText())?.groupValues?.get(1)
            ?: "unknown"
    }.getOrDefault("unknown")

    /** 把全部映射铺到 [alasDir]；返回统计，failed>0 由调用方决定是否中止启动 */
    fun apply(alasDir: File): Result {
        val flavor = readUpstreamFlavor(alasDir)
        val mappings = if (flavor == "alas") ALAS_MAPPINGS else AZURPILOT_MAPPINGS

        Timber.i("ALAS overlay: upstream_flavor=%s -> %d 条映射", flavor, mappings.size)

        var copied = 0
        var skipped = 0
        var failed = 0
        for ((assetRoot, targetRoot) in mappings) {
            val (c, s, f) = copyTree(assetRoot, File(alasDir, targetRoot))
            copied += c; skipped += s; failed += f
        }
        var removed = 0
        for (rel in STALE_FILES) {
            val stale = File(alasDir, rel)
            if (stale.isFile && stale.delete()) removed++
        }
        if (removed > 0) Timber.i("ALAS overlay stale removed: %d", removed)
        Timber.i(
            "ALAS overlay applied: flavor=%s copied=%d skipped=%d failed=%d",
            flavor, copied, skipped, failed
        )
        return Result(copied, skipped, failed, flavor)
    }

    /** 递归铺一棵资产子树；AssetManager.list 对文件返回空数组，据此区分文件/目录 */
    private fun copyTree(assetPath: String, target: File): Triple<Int, Int, Int> {
        val children = context.assets.list(assetPath) ?: return Triple(0, 0, 1)
        if (children.isEmpty()) return copyFile(assetPath, target)
        var copied = 0
        var skipped = 0
        var failed = 0
        for (name in children) {
            val (c, s, f) = copyTree("$assetPath/$name", File(target, name))
            copied += c; skipped += s; failed += f
        }
        return Triple(copied, skipped, failed)
    }

    private fun copyFile(assetPath: String, target: File): Triple<Int, Int, Int> {
        return runCatching {
            val bytes = context.assets.open(assetPath).use { it.readBytes() }
            if (target.isFile && target.readBytes().contentEquals(bytes)) {
                return Triple(0, 1, 0)
            }
            target.parentFile?.mkdirs()
            target.writeBytes(bytes)
            if (assetPath.endsWith(".sh")) target.setExecutable(true, false)
            Triple(1, 0, 0)
        }.getOrElse {
            Timber.w(it, "overlay copy failed: %s", assetPath)
            Triple(0, 0, 1)
        }
    }

    private companion object {
        /** flavor=alas：(资产子树 → /opt/alas 内目标子树)，维持历史行为 */
        val ALAS_MAPPINGS = listOf(
            "alas/overlay" to "",
            "alas/patches/module" to "module",
            "alas/patches/assets" to "assets",
            "alas/patches/assets_fix.py" to "seeds/assets_fix.py",
        )

        /**
         * flavor=azurpilot*：**只铺我方纯新增的资产**，一条都不碰上游文件。
         *
         * 刻意排除：
         * - `alas/patches/module/**`（ALAS 整文件补丁 → 会改坏上游）
         * - `alas/patches/assets/**` + `assets_fix.py`（ALAS 素材与其校准表）
         * - `alas/overlay/module/ocr/**`（我方 in-proc OCR shim → 会让上游原生
         *   RapidOCR 失效；按冻结决策「OCR 走原生」）
         * - `alas/overlay/models/ocr/azur_lane/**`（ALAS 专用字体 OCR 模型）
         *
         * 桥接接线（MRO 混入 + 方法分派 + Connection 短路）由构建期补丁注入，
         * 不在运行时覆盖 —— 见 rootfs/patches/azurpilot-android.patch。
         */
        val AZURPILOT_MAPPINGS = listOf(
            "alas/overlay/wrapper.py" to "wrapper.py",
            "alas/overlay/runner.py" to "runner.py",
            "alas/overlay/seeds" to "seeds",
            // 纯新增：桥客户端（自包含，不吃上游版本）
            "alas/patches/module/device/method/alasaos.py" to "module/device/method/alasaos.py",
        )

        /** 断代遗留的旧名文件（烘焙 tar 仍带 maaal 时代命名）：覆盖后删除，幂等 */
        val STALE_FILES = listOf(
            "module/device/method/maaal.py",
            "seeds/maaal_update.sh",
        )
    }
}
