#!/usr/bin/env python3
"""M2 · 为 AzurPilot 生成「桥接集成」最小 diff 补丁。

背景：本仓 patches/module/ 里那 10 个文件是 **ALAS 时代的整文件副本补丁**，
直接盖到 AzurPilot 上会回退上游实现（见 docs/upstream-swap-azurpilot.md §1.3）。
M2 改为**最小 diff**：只在上游源码里插入必要的接线，产出单一补丁文件
rootfs/patches/azurpilot-android.patch，构建期 git apply（冲突即构建失败）。

用法（在本仓根目录执行）：
    python3 rootfs/patches/make-azurpilot-patch.py <上游工作树> <我方 patches 目录> <输出补丁路径>
例如：
    python3 rootfs/patches/make-azurpilot-patch.py .tmp/azurpilot-src rootfs/patches \
        rootfs/patches/azurpilot-android.patch

上游工作树须与**设备上 BUILD_MANIFEST 记录的 upstream commit 一致**（否则锚点不匹配、
脚本报错退出）。树里必须同时有 `module/device/*.py` 与 `module/webui/worker_registry.py` ——
`module/webui/` 若被 sparse-checkout 排除，`worker_registry` 那两处改动会静默漏掉。

⚠️ 本脚本是补丁的**唯一真源**：改桥接接线时先改这里再重跑，不要手改 .patch 文件 ——
手改的改动会在下次重跑时被静默覆盖（2026-09-25 差点发生，详见 debug.md 同日条目）。

所有替换都带断言：锚点不存在即报错退出，绝不静默漏改。
"""
import pathlib
import shutil
import subprocess
import sys

IMPORT_ANCHOR = {
    'module/device/screenshot.py': "from module.device.method.wsa import WSA\n",
    'module/device/control.py': "from module.device.method.scrcpy import Scrcpy\n",
    'module/device/app_control.py': "from module.logger import logger\n",
}
IMPORT_LINE = "from module.device.method.alasaos import AlasAos\n"

EDITS = [
    # ---------------- screenshot.py ----------------
    ('module/device/screenshot.py',
     "class Screenshot(Adb, WSA, DroidCast, AScreenCap, Scrcpy, NemuIpc, LDOpenGL):",
     "class Screenshot(AlasAos, Adb, WSA, DroidCast, AScreenCap, Scrcpy, NemuIpc, LDOpenGL):"),
    ('module/device/screenshot.py',
     "        return {\n            'ADB': self.screenshot_adb,",
     "        return {\n            'alasaos': self.screenshot_alasaos,\n            'ADB': self.screenshot_adb,"),

    # ---------------- control.py ----------------
    ('module/device/control.py',
     "class Control(Hermit, Minitouch, Scrcpy, MaaTouch, NemuIpc):",
     "class Control(AlasAos, Hermit, Minitouch, Scrcpy, MaaTouch, NemuIpc):"),
    ('module/device/control.py',
     "        return {\n            'ADB': self.click_adb,",
     "        return {\n            'alasaos': self.click_alasaos,\n            'ADB': self.click_adb,"),
    # long_click
    ('module/device/control.py',
     "        elif method == 'nemu_ipc':\n            self.long_click_nemu_ipc(x, y, duration)\n        else:",
     "        elif method == 'nemu_ipc':\n            self.long_click_nemu_ipc(x, y, duration)\n"
     "        elif method == 'alasaos':\n            self.long_click_alasaos(x, y, duration)\n        else:"),
    # swipe 日志分支
    ('module/device/control.py',
     "        elif method in ['minitouch', 'MaaTouch', 'scrcpy', 'nemu_ipc']:",
     "        elif method in ['minitouch', 'MaaTouch', 'scrcpy', 'nemu_ipc', 'alasaos']:"),
    # swipe 执行分支
    ('module/device/control.py',
     "        elif method == 'nemu_ipc':\n            self.swipe_nemu_ipc(p1, p2)\n        else:\n"
     "            self.swipe_adb(p1, p2, duration=duration)",
     "        elif method == 'nemu_ipc':\n            self.swipe_nemu_ipc(p1, p2)\n"
     "        elif method == 'alasaos':\n            self.swipe_alasaos(p1, p2, duration=duration)\n"
     "        else:\n            self.swipe_adb(p1, p2, duration=duration)"),
    # drag
    ('module/device/control.py',
     "        elif method == 'nemu_ipc':\n            self.drag_nemu_ipc(p1, p2, point_random=point_random, "
     "hold_duration=hold_duration)\n        else:",
     "        elif method == 'nemu_ipc':\n            self.drag_nemu_ipc(p1, p2, point_random=point_random, "
     "hold_duration=hold_duration)\n"
     "        elif method == 'alasaos':\n"
     "            # AlasAos：桥只有 click/swipe 两个原语，拖拽退化为直线滑动（不支持 shake 抖动）\n"
     "            self.swipe_alasaos(p1, p2, duration=ensure_time(swipe_duration))\n        else:"),
    # island_swipe_hold
    ('module/device/control.py',
     "        elif method == 'nemu_ipc':\n            self.island_swipe_hold_nemu_ipc(p1, p2, hold_time)\n        else:",
     "        elif method == 'nemu_ipc':\n            self.island_swipe_hold_nemu_ipc(p1, p2, hold_time)\n"
     "        elif method == 'alasaos':\n            self.island_swipe_hold_alasaos(p1, p2, hold_time)\n        else:"),

    # ---------------- app_control.py ----------------
    ('module/device/app_control.py',
     "class AppControl(Adb, WSA, Uiautomator2):",
     "class AppControl(AlasAos, Adb, WSA, Uiautomator2):"),
    # app_current
    ('module/device/app_control.py',
     "        if self.is_wsa:\n            package = self.app_current_wsa()\n"
     "        elif method in AppControl._app_u2_family:",
     "        if self.is_wsa:\n            package = self.app_current_wsa()\n"
     "        elif method == 'alasaos':\n            package = self.app_current_alasaos()\n"
     "        elif method in AppControl._app_u2_family:"),
    # app_start
    ('module/device/app_control.py',
     "        if self.config.Emulator_Serial == 'wsa-0':\n            self.app_start_wsa(display=0)\n"
     "        elif method in AppControl._app_u2_family:",
     "        if self.config.Emulator_Serial == 'wsa-0':\n            self.app_start_wsa(display=0)\n"
     "        elif method == 'alasaos':\n            self.app_start_alasaos()\n"
     "        elif method in AppControl._app_u2_family:"),
    # app_stop
    ('module/device/app_control.py',
     "        if method in AppControl._app_u2_family:\n            self.app_stop_uiautomator2()\n        else:\n"
     "            self.app_stop_adb()",
     "        if method == 'alasaos':\n            self.app_stop_alasaos()\n"
     "        elif method in AppControl._app_u2_family:\n            self.app_stop_uiautomator2()\n        else:\n"
     "            self.app_stop_adb()"),
    # dump_hierarchy
    ('module/device/app_control.py',
     "        if method in AppControl._app_u2_family:\n            self.hierarchy = self.dump_hierarchy_uiautomator2()\n"
     "        else:\n            self.hierarchy = self.dump_hierarchy_adb()",
     "        if method == 'alasaos':\n            self.hierarchy = self.dump_hierarchy_alasaos()\n"
     "        elif method in AppControl._app_u2_family:\n            self.hierarchy = self.dump_hierarchy_uiautomator2()\n"
     "        else:\n            self.hierarchy = self.dump_hierarchy_adb()"),

    # ---------------- connection.py ----------------
    ('module/device/connection.py',
     "        super().__init__(config)\n        if not self.is_over_http:\n            self.detect_device()",
     "        super().__init__(config)\n"
     "        # AlasAos BEGIN: 桥接模式（serial 以 alasaos 开头）没有本地 adb 设备，\n"
     "        # 跳过 detect_device / adb_connect / detect_package / check_mumu_app_keep_alive，\n"
     "        # 包名直接取配置（auto 时落 CN 默认包名），set_server 保持资源服务器正确。\n"
     "        if str(self.serial).startswith('alasaos'):\n"
     "            self.package = self.config.Emulator_PackageName\n"
     "            if self.package == 'auto':\n"
     "                self.package = 'com.bilibili.azurlane'\n"
     "            set_server(self.package)\n"
     "            logger.attr('应用包名', self.package)\n"
     "            logger.attr('服务器', self.config.SERVER)\n"
     "            logger.info('AlasAos 桥接模式：跳过 adb 设备检测')\n"
     "            return\n"
     "        # AlasAos END\n"
     "        if not self.is_over_http:\n            self.detect_device()"),

    # ---------------- connection_attr.py ----------------
    # ⚠️ 必须在这里短路：ConnectionAttr.__init__ 里 `self.adb_binary`（约 127 行）
    # 会走「自动下载 platform-tools」分支，而 Connection.__init__ 的桥接判断在
    # super().__init__() **之后**，拦不住。Android 上 dl.google.com 不可达 →
    # 解压 BadZipFile 直接中断设备初始化（真机 16:14:00 触发、16:16:03 抛错，
    # 白等 123 秒；用户表现为「点进去黑屏、没反应，等一会才能进」）。
    ('module/device/connection_attr.py',
     "        # Init adb client\n"
     "        logger.attr('ADB路径', self.adb_binary)\n"
     "        # Monkey patch to custom adb\n"
     "        adbutils.adb_path = lambda: self.adb_binary\n",
     "        # AlasAos BEGIN: 桥接模式（serial 以 alasaos 开头）没有本地 adb 二进制。\n"
     "        # 必须在此短路：下面的 self.adb_binary 会走「自动下载 platform-tools」分支，\n"
     "        # 而 Android 上 dl.google.com 不可达 → 解压报 BadZipFile 并直接中断设备初始化\n"
     "        # （真机实测 16:14:00 触发下载、16:16:03 抛错，白等 123 秒后设备初始化失败）。\n"
     "        # 注：Connection.__init__ 里的桥接判断在 super().__init__() 之后，拦不住这里。\n"
     "        alasaos_bridge = str(self.config.Emulator_Serial).strip().startswith('alasaos')\n"
     "        if alasaos_bridge:\n"
     "            logger.attr('ADB路径', '(alasaos 桥接：无需本地 adb)')\n"
     "        else:\n"
     "            # Init adb client\n"
     "            logger.attr('ADB路径', self.adb_binary)\n"
     "            # Monkey patch to custom adb\n"
     "            adbutils.adb_path = lambda: self.adb_binary\n"
     "        # AlasAos END\n"),
    ('module/device/connection_attr.py',
     "        # Cache adb_client\n"
     "        _ = self.adb_client\n",
     "        # Cache adb_client\n"
     "        # AlasAos BEGIN: 桥接模式不建 adb 客户端（AdbClient 会去探 adb server）\n"
     "        if not alasaos_bridge:\n"
     "            _ = self.adb_client\n"
     "        # AlasAos END\n"),
    ('module/device/connection_attr.py',
     "        from module.webui.setting import State\n\n"
     "        # 统一使用绝对路径检查，避免相对路径导致的 CWD 问题\n",
     "        # AlasAos BEGIN: 桥接模式即便本属性被访问也不做探测/下载（幂等防护）\n"
     "        if str(self.config.Emulator_Serial).strip().startswith('alasaos'):\n"
     "            return ''\n"
     "        # AlasAos END\n"
     "        from module.webui.setting import State\n\n"
     "        # 统一使用绝对路径检查，避免相对路径导致的 CWD 问题\n"),

    # ---------------- worker_registry.py ----------------
    # Android 内核拒绝 app 进程读 /proc（PermissionError: '/proc/stat'），
    # 上游用 psutil 做 worker 进程自查，两处失败即 raise：
    #   _process_created_at() → claim_owner 未捕获 → WebUI 启动即炸 / 点挂机报错
    #   process_matches()     → _record_is_alive 保守返回 True → 误判「旧实例还在」
    ('module/webui/worker_registry.py',
     "    except Exception as exc:\n"
     '        raise RuntimeError(f"无法读取 worker PID {pid} 的创建时间: {exc}") from exc',
     "    except Exception as exc:\n"
     "        # [ALAS-AOS] Android/proot：psutil 需要读 /proc，而 app 进程读 /proc/stat 与\n"
     "        # /proc/<pid>/stat 被内核拒绝（实测 PermissionError: '/proc/stat'）。\n"
     "        # 本进程与它拉起的 worker 进程都读不到 → 一律降级为「登记时刻」近似；\n"
     "        # 配套 process_matches() 在同类失败下返回 None（无法确认），上层按「非存活」处理。\n"
     "        # 代价：Android 上 worker 存活探测失效（孤儿回收不可用），但不阻塞启动与挂机。\n"
     "        created_at = time.time()"),
    ('module/webui/worker_registry.py',
     '        raise RuntimeError(f"无法验证 worker PID {pid}: {exc}") from exc',
     "        # [ALAS-AOS] 同上：无法确认时返回 None，让上层按「非存活」处理。\n"
     "        return None"),
]

# 追加到 alasaos.py 的岛屿摇杆方法（AzurPilot 的 island_swipe_hold 需要）
EXTRA_METHOD = '''
    def island_swipe_hold_alasaos(self, p1, p2, hold_time):
        """岛屿摇杆：两点间滑动 + 终点保持。

        AzurPilot 的 island_swipe_hold 传入的是**毫秒**（minitouch 的
        CommandBuilder.wait 语义）。桥只有 swipe(duration 秒) 一个原语，
        故用「滑动时长 = 保持时长」近似终点保持；下限 0.1s 避免退化成点击。
        """
        duration = max(0.1, int(hold_time) / 1000.0)
        self.swipe_alasaos(p1, p2, duration=duration)

'''


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    tree = pathlib.Path(sys.argv[1]).resolve()
    our_patches = pathlib.Path(sys.argv[2]).resolve()
    out_patch = pathlib.Path(sys.argv[3]).resolve()

    if not (tree / 'module/device/connection.py').is_file():
        print(f'!! 不是 AzurPilot 工作树: {tree}')
        return 1

    # --- 1. 装 alasaos.py（纯新增文件） ---
    src = our_patches / 'module/device/method/alasaos.py'
    dst = tree / 'module/device/method/alasaos.py'
    text = src.read_text(encoding='utf-8')
    anchor = '    def get_orientation(self):'
    assert anchor in text, 'alasaos.py 里找不到 get_orientation 锚点'
    text = text.replace(anchor, EXTRA_METHOD.lstrip('\n') + anchor, 1)
    dst.write_text(text, encoding='utf-8')
    print(f'[1] 写入 {dst.relative_to(tree)}（含新增 island_swipe_hold_alasaos）')

    # --- 2. 加 import ---
    for rel, anchor in IMPORT_ANCHOR.items():
        p = tree / rel
        t = p.read_text(encoding='utf-8')
        assert anchor in t, f'{rel}: import 锚点缺失'
        if IMPORT_LINE in t:
            continue
        p.write_text(t.replace(anchor, anchor + IMPORT_LINE, 1), encoding='utf-8')
        print(f'[2] {rel}: 已加 import')

    # --- 3. 逐条接线（带断言） ---
    n = 0
    for rel, old, new in EDITS:
        p = tree / rel
        t = p.read_text(encoding='utf-8')
        if old not in t:
            print(f'!! 锚点缺失，未做改动：{rel}\n   >>> {old[:90]!r}')
            return 1
        if t.count(old) != 1:
            print(f'!! 锚点不唯一（{t.count(old)} 次）：{rel}\n   >>> {old[:90]!r}')
            return 1
        p.write_text(t.replace(old, new, 1), encoding='utf-8')
        n += 1
    print(f'[3] 接线插入 {n} 处，全部命中唯一锚点')

    # --- 4. 生成补丁 ---
    r = subprocess.run(['git', '-C', str(tree), 'diff', '--', 'module/'],
                       capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        print('!! git diff 失败:', r.stderr)
        return 1
    # 未跟踪的 alasaos.py 不进 diff，用 --no-index 单独补一段
    r2 = subprocess.run(['git', '-C', str(tree), 'diff', '--no-index', '--binary',
                         '/dev/null', 'module/device/method/alasaos.py'],
                        capture_output=True, text=True, encoding='utf-8')
    patch = r.stdout
    # ⚠️ 必须显式 newline='\n'：Path.write_text() 默认会把 \n 翻成 os.linesep，
    # 在 Windows 上产出 CRLF 补丁 —— 而上游 .gitattributes 声明 *.py eol=lf，
    # Linux 构建机的工作树是 LF，CRLF 补丁 git apply 必然失败（已实测踩到）。
    out_patch.write_text(patch, encoding='utf-8', newline='\n')
    crlf = sum(1 for line in patch.split('\n') if line.endswith('\r'))
    print(f'[4] 补丁已写入 {out_patch}（{len(patch.splitlines())} 行，'
          f'含 {patch.count("+++")} 个文件，CRLF 行 {crlf}）')
    if crlf:
        print('!! 补丁里仍有 CRLF —— 构建机会失败，请检查生成流程')
        return 1
    print('    行尾 LF ✅；alasaos.py 是**新增文件**，由 build-rootfs.sh 单独 install，')
    print('    不放进补丁（避免 --no-index 的 a//b/ 前缀问题）。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
