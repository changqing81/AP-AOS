#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""桩测试：alasaos_bootstrap 2026-10-07 三处修复（A=MRO / B=不回退 / C=双头停止）。

搭法：
- 假上游树（sys.modules 注入），AlasAos 用 rootfs/patches 的**真实源码**按路径加载
  （importlib 加载本仓受控文件，不用 exec）；
- 假桥代理（**裸 JSON 行协议**，非 HTTP，与真代理同款；端口 22399）；
- 假 wrapper（22400 收 POST /stop 并记录；wrapper 真身是 HTTP）；
- 覆盖：MRO 接线与幂等 / 桥接端到端 / 桥失败原样抛不回退 / 非桥接走上游 /
  process_manager 预停（terminate + 转发 /stop + 属性缺失兜底）。

正式位置：rootfs/seeds/（按文件自身位置上溯定位仓库；build-rootfs.sh 对 seeds
按**显式文件名**安装，本文件不会被卷进 rootfs）。
跑法：`python rootfs/seeds/test_bootstrap_fix.py`，期望末行 `ALL GREEN`。

教训（2026-09-25 自证陷阱的对策）：桩测试必须从「上游原版类定义」出发搭建，
不能复刻被测补丁想要的结果；假桥协议要对齐真桥（裸 JSON 行 ≠ HTTP）。
"""
import importlib.util
import json
import os
import sys
import tempfile
import threading
import types
import socketserver
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
os.environ['ALASAOS_BOOTSTRAP_NO_AUTOINSTALL'] = '1'
os.environ['ALASAOS_ALAS_ROOT'] = tempfile.mkdtemp(prefix='alasaos_bootstrap_test_')
BRIDGE_PORT = 22399

PASS, FAIL = [], []


def check(name, cond, extra=''):
    (PASS if cond else FAIL).append(name)
    print(('  ok  ' if cond else '  FAIL') + f' | {name}' + (f' | {extra}' if extra and not cond else ''))


# ---------------------------------------------------------------- 假上游树

def mkmod(name):
    m = types.ModuleType(name)
    sys.modules[name] = m
    return m


for pkg in ('module', 'module.base', 'module.device', 'module.webui'):
    mkmod(pkg)

base_dec = mkmod('module.base.decorator')


def cached_property(func):
    class _CP:
        def __init__(self, f):
            self.func = f
            self.attrname = f.__name__

        def __get__(self, obj, objtype=None):
            if obj is None:
                return self
            val = self.func(obj)
            setattr(obj, self.attrname, val)
            return val
    return _CP(func)


base_dec.cached_property = cached_property

mod_exc = mkmod('module.exception')


class RequestHumanTakeover(Exception):
    pass


class ScriptError(Exception):
    pass


mod_exc.RequestHumanTakeover = RequestHumanTakeover
mod_exc.ScriptError = ScriptError

mod_log = mkmod('module.logger')


class _Logger:
    def attr(self, *a, **k):
        pass

    def info(self, *a, **k):
        pass

    def warning(self, *a, **k):
        pass

    def error(self, *a, **k):
        pass

    def critical(self, *a, **k):
        pass

    def debug(self, *a, **k):
        pass


mod_log.logger = _Logger()

mkmod('numpy')  # alasaos.py import 时仅要求可导入

# 真实 alasaos.py 源码（本仓受控文件，按路径加载）
src_path = os.path.join(REPO, 'rootfs', 'patches', 'module', 'device', 'method', 'alasaos.py')
spec = importlib.util.spec_from_file_location('module.device.method.alasaos', src_path)
alasaos_mod = importlib.util.module_from_spec(spec)
sys.modules['module.device.method.alasaos'] = alasaos_mod
spec.loader.exec_module(alasaos_mod)
AlasAos = alasaos_mod.AlasAos

# ---------------------------------------------------------------- 假桥代理

BRIDGE_SEEN = []          # 收到的请求
BRIDGE_FAIL_METHODS = set()  # 这些 method 回 ok=False，用于测 Fix B


class _BridgeHandler(socketserver.BaseRequestHandler):
    """真桥客户端协议：裸 JSON 行（非 HTTP），一连接可发多条请求。"""

    def handle(self):
        f = self.request.makefile('rb')
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line.decode('utf-8'))
            except Exception:
                return
            BRIDGE_SEEN.append(req)
            method = req.get('method')
            if method in BRIDGE_FAIL_METHODS:
                resp = {'ok': False, 'id': req.get('id'), 'error': 'fake bridge failure'}
            elif method == 'shell':
                cmd = req.get('cmd', '')
                if 'dumpsys display' in cmd:
                    # 真机管道输出经两道 grep + tail 后只剩数字
                    out = '3'
                elif 'dumpsys window displays' in cmd:
                    out = ('Display 0 (displayId=0): ...\n'
                           '  mCurrentFocus=Window{123 u0 com.android.launcher/...}\n'
                           'Display 3 (displayId=3): ...\n'
                           '  mCurrentFocus=Window{456 u0 com.bilibili.azurlane/com.manjuu.azurlane.MainActivity}')
                else:
                    out = ''
                resp = {'ok': True, 'id': req.get('id'), 'code': 0, 'stdout': out, 'stderr': ''}
            else:
                resp = {'ok': True, 'id': req.get('id')}
            self.request.sendall(json.dumps(resp).encode('utf-8') + b'\n')


class _BridgeServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


BRIDGE_SEEN.clear()
bridge_srv = _BridgeServer(('127.0.0.1', BRIDGE_PORT), _BridgeHandler)
threading.Thread(target=bridge_srv.serve_forever, daemon=True).start()
os.environ['ALASAOS_PROXY_ADDR'] = f'127.0.0.1:{BRIDGE_PORT}'

# ---------------------------------------------------------------- 假 wrapper（22400）

WRAPPER_POSTS = []


class _WrapHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            self.rfile.read(n)
        WRAPPER_POSTS.append(self.path)
        body = json.dumps({'runner_alive': False, 'was_alive': True, 'exit_code': 1}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body)


wrap_srv = HTTPServer(('127.0.0.1', 22400), _WrapHandler)
threading.Thread(target=wrap_srv.serve_forever, daemon=True).start()

# ---------------------------------------------------------------- 被测模块

sys.path.insert(0, os.path.join(REPO, 'rootfs', 'seeds'))
import alasaos_bootstrap as ab  # noqa: E402

# ---------------------------------------------------------------- 假上游 device 树

control_mod = mkmod('module.device.control')
from module.base.decorator import cached_property as _cp  # 假版 cached_property  # noqa: E402


class Control:
    # 与上游同构：click 按 click_methods 分派 dict 取方法（注入器会往 dict 塞 'alasaos'）
    @staticmethod
    def _click_methods_inner(self):
        return {'adb': self.click_adb}

    @cached_property
    def click_methods(self):
        return Control._click_methods_inner(self)

    def click_adb(self, x, y):
        return ('UPSTREAM_CLICK', x, y)

    def click(self, x, y):
        return self.click_methods[self.config.Emulator_ControlMethod](x, y)

    def swipe(self, p1, p2, duration=0.5):
        return ('UPSTREAM_SWIPE', p1, p2, duration)


control_mod.Control = Control

app_mod = mkmod('module.device.app_control')
UPSTREAM_CALLED = []


class _Adb:
    def app_current(self):
        UPSTREAM_CALLED.append('app_current')
        return 'UPSTREAM_CURRENT'

    def app_stop(self, package=None):
        UPSTREAM_CALLED.append('app_stop')
        return 'UPSTREAM_STOP'


class _WSA:
    pass


class _Uiautomator2:
    pass


class AppControl(_Adb, _WSA, _Uiautomator2):
    pass


app_mod.AppControl = AppControl

print('== Fix A：MRO 接线 ==')
done = ab._patch_app_control(app_mod)
check('A1 AlasAos 进入 AppControl.__mro__', AlasAos in AppControl.__mro__)
check('A2 done 记录 bases 注入', any('bases' in d for d in done), str(done))
check('A3 幂等：二次注入不重复改 bases',
      AppControl.__bases__[0] is AlasAos and
      AppControl.__bases__.count(AlasAos) == 1)

done2 = ab._patch_control(control_mod)
check('A4 Control 注入完成', len(done2) >= 4, str(done2))


class _Cfg:
    def __init__(self, serial):
        self.Emulator_Serial = serial
        self.Emulator_ControlMethod = 'alasaos' if serial.startswith('alasaos') else 'adb'


class Device(Control, AppControl):
    def __init__(self, serial='alasaos'):
        self.config = _Cfg(serial)
        self.serial = serial
        self.package = 'com.bilibili.azurlane'


dev = Device()

print('== Fix A：桥接端到端（截图/当前应用走桥，不碰真 adb）==')
cur = dev.app_current()
check('A5 app_current 走桥返回包名', cur == 'com.bilibili.azurlane', repr(cur))
check('A6 上游 app_current 未被触碰', 'app_current' not in UPSTREAM_CALLED)
check('A7 桥收到 shell 请求', any(r.get('method') == 'shell' for r in BRIDGE_SEEN))
BRIDGE_SEEN.clear()

print('== Fix B：桥失败原样抛，不回退上游 ==')
BRIDGE_FAIL_METHODS.add('shell')
try:
    dev.app_current()
    check('B1 桥失败应抛异常', False, '没有抛')
except RequestHumanTakeover:
    check('B1 桥不可达抛 RequestHumanTakeover', True)
except ScriptError:
    check('B1 桥失败抛 ScriptError', True)
except Exception as e:
    check('B1 桥失败抛预期异常', False, repr(e))
check('B2 失败时未回退上游 app_current', 'app_current' not in UPSTREAM_CALLED,
      str(UPSTREAM_CALLED))
BRIDGE_FAIL_METHODS.clear()
UPSTREAM_CALLED.clear()

print('== Fix B：非桥接模式走上游 ==')
dev_pc = Device('127.0.0.1:5555')
check('B3 非桥接 app_current 走上游', dev_pc.app_current() == 'UPSTREAM_CURRENT')
check('B4 非桥接 click 走上游', dev_pc.click(1, 2)[0] == 'UPSTREAM_CLICK')

print('== Fix B：Control 桥失败不回退 ==')
BRIDGE_FAIL_METHODS.add('click')
try:
    dev.click(5, 6)
    check('B5 click 桥失败应抛', False)
except ScriptError:
    check('B5 click 桥失败抛 ScriptError（不回退）', True)
except Exception as e:
    check('B5 click 桥失败抛预期异常', False, repr(e))
BRIDGE_FAIL_METHODS.clear()
check('B6 桥接 click 正常走桥（上一步失败后恢复）', (dev.click(7, 8) is None))
BRIDGE_SEEN.clear()

print('== Fix C：process_manager 预停 ==')
pm_mod = mkmod('module.webui.process_manager')


class FakeProc:
    def __init__(self):
        self.alive = True
        self.terminated = False
        self.pid = 4321

    def is_alive(self):
        return self.alive

    def terminate(self):
        self.terminated = True
        self.alive = False

    def join(self, timeout=None):
        pass


class ProcessManager:
    def __init__(self):
        self._process = FakeProc()
        self.orig_ran = False

    def _stop_worker_locked(self):
        self.orig_ran = True
        proc = getattr(self, '_process', None)
        return ('ORIG_RESULT', proc.terminated if proc is not None else None)


pm_mod.ProcessManager = ProcessManager

done3 = ab._patch_process_manager(pm_mod)
check('C1 注入记录', any('pre-stop' in d for d in done3), str(done3))

WRAPPER_POSTS.clear()
mgr = ProcessManager()
ret = mgr._stop_worker_locked()
check('C2 自有 worker 已 terminate', mgr._process.terminated)
check('C3 wrapper 收到 POST /stop', '/stop' in WRAPPER_POSTS, str(WRAPPER_POSTS))
check('C4 原方法仍执行且返回值透传', ret == ('ORIG_RESULT', True), repr(ret))

# 已死 worker：不重复 terminate，但仍转发 wrapper
WRAPPER_POSTS.clear()
mgr2 = ProcessManager()
mgr2._process.alive = False
mgr2._process.terminated = False
mgr2._stop_worker_locked()
check('C5 已死 worker 不重复 terminate', not mgr2._process.terminated)
check('C6 仍转发 wrapper /stop', '/stop' in WRAPPER_POSTS)

# 缺 _process 属性：不炸，原方法照常
mgr3 = ProcessManager()
del mgr3._process
mgr3._stop_worker_locked()
check('C7 无 _process 属性不炸且原方法执行', mgr3.orig_ran)

print()
print(f'PASS {len(PASS)} / FAIL {len(FAIL)}')
if FAIL:
    print('FAILED:', FAIL)
    sys.exit(1)
print('ALL GREEN')
