"""AlasAos 桥接 method：设备 I/O 全部经 TCP 代理转发到 MaaFwApp 特权进程。

代理（spike/m0/agent/main.py）在手机上监听 127.0.0.1:22300，协议为行分隔 JSON + 二进制帧：
    ping/screencap/click/swipe/ocr/shell，详见代理源文件 docstring。

启用方式：Emulator_Serial 以 "alasaos" 开头（默认 serial 即 "alasaos"），
截图/控制方法选择 "alasaos"。本模块不 import 任何 adb/u2 依赖。

注意：
- MaaFW 截图为 BGR 序，ALAS 图像为 RGB 序，screenshot_alasaos 负责翻通道。
- 游戏必须跑在 MaaFwApp 的虚拟屏上：app_start_alasaos 用 `am start --display <VID>`，
  VID 由代理侧 shell 探测（dumpsys display 找 VIRTUAL displayId），每轮进程缓存一次。
- get_orientation 对桥接固定返回 0（虚拟屏始终横屏 1280x720）。
- dump_hierarchy 反映的是物理屏 UI 树（uiautomator 看不到虚拟屏），仅作兜底。
"""
import json
import re
import socket
import time

import numpy as np

from module.base.decorator import cached_property
from module.exception import RequestHumanTakeover, ScriptError
from module.logger import logger

ALASAOS_DEFAULT_ADDR = '127.0.0.1:22300'


class AlasAosBridgeError(Exception):
    pass


class AlasAos:
    _alasaos_sock = None
    _alasaos_req_id = 0

    # ---------------------------------------------------------------- 协议层

    @cached_property
    def alasaos_addr(self) -> str:
        import os
        return os.environ.get('ALASAOS_PROXY_ADDR', ALASAOS_DEFAULT_ADDR)

    def _alasaos_connect(self) -> socket.socket:
        host, _, port = self.alasaos_addr.partition(':')
        sock = socket.create_connection((host, int(port)), timeout=10)
        sock.settimeout(60)
        return sock

    def _alasaos_call(self, payload: dict, frame: bytes = None) -> dict:
        """发送一条请求（可随附一帧二进制），返回响应 dict。连接错误重连重试一次。"""
        AlasAos._alasaos_req_id += 1
        payload = dict(payload)
        payload['id'] = AlasAos._alasaos_req_id

        last_error = None
        for _ in range(2):
            try:
                sock = AlasAos._alasaos_sock
                if sock is None:
                    sock = AlasAos._alasaos_sock = self._alasaos_connect()
                sock.sendall(json.dumps(payload, separators=(',', ':')).encode('utf-8') + b'\n')
                if frame is not None:
                    sock.sendall(frame)
                # 逐字节读响应行：screencap 响应行后紧跟像素帧，大块读会吞帧
                buf = b''
                while not buf.endswith(b'\n'):
                    data = sock.recv(1)
                    if not data:
                        raise AlasAosBridgeError('proxy closed connection')
                    buf += data
                    if len(buf) > 256 * 1024:
                        raise AlasAosBridgeError('response line too long')
                return json.loads(buf.decode('utf-8'))
            except (OSError, AlasAosBridgeError, json.JSONDecodeError) as e:
                last_error = e
                logger.warning(f'AlasAos proxy error: {e}, reconnect')
                try:
                    if AlasAos._alasaos_sock is not None:
                        AlasAos._alasaos_sock.close()
                except OSError:
                    pass
                AlasAos._alasaos_sock = None
        logger.critical(f'AlasAos proxy unreachable: {last_error}')
        raise RequestHumanTakeover

    def _alasaos_call_ok(self, payload: dict, frame: bytes = None) -> dict:
        resp = self._alasaos_call(payload, frame)
        if not resp.get('ok'):
            raise ScriptError(f'AlasAos proxy error: {resp.get("error", "unknown")}')
        return resp

    def _alasaos_read_exact(self, n: int) -> bytes:
        sock = AlasAos._alasaos_sock
        chunks = []
        while n > 0:
            data = sock.recv(min(1048576, n))
            if not data:
                raise AlasAosBridgeError('connection closed mid-frame')
            chunks.append(data)
            n -= len(data)
        return b''.join(chunks)

    # ---------------------------------------------------------------- 截图 / 触控

    def screenshot_alasaos(self) -> np.ndarray:
        resp = self._alasaos_call_ok({'method': 'screencap'})
        raw = self._alasaos_read_exact(int(resp['length']))
        image = np.frombuffer(raw, dtype=np.uint8).reshape(
            int(resp['height']), int(resp['width']), int(resp['channels']))
        # BGR(A) -> RGB（ALAS 图像约定 RGB 序）
        if image.shape[2] >= 3:
            image = image[..., :3][..., ::-1]
        return np.ascontiguousarray(image)

    def click_alasaos(self, x, y):
        self._alasaos_call_ok({'method': 'click', 'x': int(x), 'y': int(y)})

    def long_click_alasaos(self, x, y, duration):
        # 等效长按：原地滑动，duration 单位为秒（ALAS 约定），代理侧为毫秒
        self._alasaos_call_ok({
            'method': 'swipe',
            'x1': int(x), 'y1': int(y), 'x2': int(x), 'y2': int(y),
            'duration': int(duration * 1000),
        })

    def swipe_alasaos(self, p1, p2, duration=0.1):
        self._alasaos_call_ok({
            'method': 'swipe',
            'x1': int(p1[0]), 'y1': int(p1[1]),
            'x2': int(p2[0]), 'y2': int(p2[1]),
            'duration': int(duration * 1000),
        })

    # ---------------------------------------------------------------- shell 通道

    def alasaos_shell(self, cmd: str, timeout: float = 30) -> dict:
        """经代理以 shell uid 执行系统命令，返回 {ok, code, stdout, stderr}。"""
        return self._alasaos_call({'method': 'shell', 'cmd': cmd, 'timeout': timeout})

    def alasaos_shell_output(self, cmd: str, timeout: float = 30) -> str:
        resp = self.alasaos_shell(cmd, timeout)
        if not resp.get('ok'):
            raise ScriptError(f'AlasAos shell failed: {cmd!r}: {resp.get("stderr", "")[:200]}')
        return resp.get('stdout', '')

    @cached_property
    def alasaos_display_id(self) -> int:
        out = self.alasaos_shell_output(
            "dumpsys display | grep -oE 'type=VIRTUAL, [^}]*displayId=[0-9]+' | grep -oE '[0-9]+' | tail -1"
        ).strip()
        if not out.isdigit():
            raise ScriptError(f'AlasAos virtual display not found: {out!r}')
        logger.attr('AlasAos', f'virtual display id={out}')
        return int(out)

    # ---------------------------------------------------------------- App 控制

    def app_start_alasaos(self, package=None, activity=None, wait=True):
        from module.config.server import DICT_PACKAGE_TO_ACTIVITY
        package = package or self.package
        if activity is None:
            activity = DICT_PACKAGE_TO_ACTIVITY.get(package)
            if activity is None:
                raise ScriptError(f'No known activity for package: {package}')
        self.alasaos_shell_output(
            f'am start --display {self.alasaos_display_id} -n {package}/{activity}')
        if wait:
            time.sleep(1)

    def app_stop_alasaos(self, package=None):
        self.alasaos_shell_output(f'am force-stop {package or self.package}')

    def app_current_alasaos(self) -> str:
        """虚拟屏的前台应用包名。dumpsys window displays 按 displayId 分块，
        取目标块内的 mCurrentFocus；找不到则回退 pidof 判定。"""
        out = self.alasaos_shell_output('dumpsys window displays')
        vid = self.alasaos_display_id
        current = ''
        for block in re.split(r'\n\s*(?=Display )', out):
            if f'displayId={vid}' in block:
                m = re.search(r'mCurrentFocus=\S+\s*\{[^}]*?\s([\w.]+)/[\w.]+', block)
                if m:
                    current = m.group(1)
                break
        if not current:
            resp = self.alasaos_shell(f'pidof {self.package}')
            current = self.package if resp.get('ok') and resp.get('stdout', '').strip() else ''
        logger.attr('App current (alasaos)', current)
        return current

    def island_swipe_hold_alasaos(self, p1, p2, hold_time):
        """岛屿摇杆：两点间滑动 + 终点保持。

        AzurPilot 的 island_swipe_hold 传入的是**毫秒**（minitouch 的
        CommandBuilder.wait 语义）。桥只有 swipe(duration 秒) 一个原语，
        故用「滑动时长 = 保持时长」近似终点保持；下限 0.1s 避免退化成点击。

        注：本方法原先由补丁生成器在构建期动态插入，改用运行时注入后直接
        落在本文件里（少一层动态改写，也让注入侧能按同一签名调用）。
        """
        duration = max(0.1, int(hold_time) / 1000.0)
        self.swipe_alasaos(p1, p2, duration=duration)

    def get_orientation(self):
        """桥接模式下虚拟屏始终横屏 1280x720，直接返回 0。
        注意：本方法在 AlasAos 混入类上，MRO 先于 Connection 的 adb 实现。"""
        if str(self.serial).startswith('alasaos'):
            self.orientation = 0
            return 0
        return super().get_orientation()

    def dump_hierarchy_alasaos(self):
        """兜底实现：uiautomator dump 看到的是物理屏 UI 树（虚拟屏内容不可见）。
        仅用于不依赖游戏画面的系统级弹窗处理；游戏内 UI 不应走这里。"""
        from lxml import etree
        logger.warning('dump_hierarchy on alasaos reflects the PHYSICAL display, not the virtual one')
        out = self.alasaos_shell_output(
            'uiautomator dump /data/local/tmp/alasaos_ui.xml >/dev/null 2>&1; '
            'cat /data/local/tmp/alasaos_ui.xml', timeout=60)
        self.hierarchy = etree.fromstring(out.encode('utf-8'))
        return self.hierarchy
