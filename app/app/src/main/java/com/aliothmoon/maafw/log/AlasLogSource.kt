package com.aliothmoon.maafw.log

import android.content.Context
import java.io.File

/**
 * ALAS 侧日志目录（proot 内 `/opt/alas/log`，实体在内部存储 rootfs 下）的唯一访问口
 *
 * App 进程直接可读，不走 wrapper HTTP：wrapper 的 /logs 只服务 mtime 最新的一个 txt，
 * 历史 txt 与 error 现场根本拿不到；路径拼法与 `ProotHost` 的 alasDir 一致
 *
 * adb 读不到内部存储（release 无 run-as），所以查看/导出都得在 App 进程内做
 *
 * ## 两代上游的日志布局差异（2026-09-24 核实上游 `module/logger.py`）
 *
 * - **ALAS 时代**：`log/{YYYY-MM-DD}_{config}.txt` 每天一个文件；出错时落
 *   `log/error/{毫秒}/`（log.txt + 截图），即「错误记录」分区的数据源。
 * - **AzurPilot（现行上游）**：改用 `TimedRotatingFileHandler` 写
 *   **`log/{name}.txt`**（无日期前缀，如 `alas.txt`），午夜轮转，旧文件按
 *   `LogBackUpMethod` 落到 **`log/bak/`**（默认 copy ⇒ `bak/alas.txt.2026-09-23`；
 *   gui 进程用 zip ⇒ `bak/xxx.zip`）。且**不再有 `log/error/` 现场目录** ——
 *   错误改由 `error_context()` 结构化写进日志正文。
 *
 * 因此本类同时兼容两代命名；`errorDirs()` 在新上游下恒空，UI 的「错误记录」
 * 分区因 `isNotEmpty()` 判断自然不渲染（保留实现以兼容 flavor=alas 的旧包）。
 */
class AlasLogSource(context: Context) {

    private val logDir: File = File(context.filesDir, "rootfs/opt/alas/log")
    private val bakDir: File = File(logDir, "bak")

    fun logDir(): File = logDir

    /** 当前日志 + 轮转归档的文本日志，mtime 倒序
     *
     * 两代命名都收：`2026-09-24_alas.txt`（ALAS）、`alas.txt`（新上游当前）、
     * `alas.txt.2026-09-23`（新上游轮转进 `bak/`）。
     *
     * 归档目录里可能有 zip/tar.bz2（gui 进程用 zip 模式），**必须排除** ——
     * 它们不是文本，点开只会显示乱码。
     */
    fun dailyLogs(): List<File> = runCatching {
        val current = logDir.listFiles()
            ?.filter { it.isFile && isPlainTextLog(it.name) }
            .orEmpty()
        val archived = bakDir.listFiles()
            ?.filter { it.isFile && isPlainTextLog(it.name) }
            .orEmpty()
        (current + archived).sortedByDescending { it.lastModified() }
    }.getOrDefault(emptyList())

    /** 错误现场 `error/<毫秒时间戳>/`，时间戳倒序；名字非纯数字的目录不收
     *
     * 注：现行上游（AzurPilot）已无此目录 ⇒ 恒返回空。保留是为了兼容旧烘焙包。
     */
    fun errorDirs(): List<File> = runCatching {
        File(logDir, "error").listFiles()
            ?.filter { it.isDirectory && it.name.all(Char::isDigit) }
            ?.sortedByDescending { it.name.toLongOrNull() ?: 0L }
            .orEmpty()
    }.getOrDefault(emptyList())

    /** 按名单取日志（先 `log/` 再 `log/bak/`）；拒绝路径段，防路由参数越出日志目录 */
    fun dailyFile(name: String): File? =
        name.takeIf { it.isNotBlank() && !it.contains('/') && !it.contains("..") }
            ?.let { listOf(File(logDir, it), File(bakDir, it)) }
            ?.firstOrNull { it.isFile }

    /** 按目录名取错误现场；同样是路由参数，先验纯数字 */
    fun errorDir(name: String): File? =
        name.takeIf { it.isNotBlank() && it.all(Char::isDigit) }
            ?.let { File(File(logDir, "error"), it) }
            ?.takeIf { it.isDirectory }

    /** 是否是可直接当文本读的日志（排除 zip/tar/bz2 等轮转归档） */
    private fun isPlainTextLog(name: String): Boolean {
        val lower = name.lowercase()
        if (lower.endsWith(".zip") || lower.endsWith(".bz2") ||
            lower.endsWith(".gz") || lower.endsWith(".tar")
        ) return false
        // `alas.txt` 或 `alas.txt.2026-09-23`（TimedRotatingFileHandler 的 copy 命名）
        return lower.endsWith(".txt") || lower.contains(".txt.")
    }
}
