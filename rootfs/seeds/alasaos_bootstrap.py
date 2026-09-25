#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AlasAos · 桥接接线运行时注入（**零改上游文件**）。

为什么不用 patch
----------------
patch（`azurpilot-android.patch`）改的全是**上游跟踪文件**，上游一提交就失效、
每次都要重打；更糟的是失败是**静默**的（2026-09-25 真机事故：GUI 更新器把代码
拉到新 commit，补丁没重放 → 上游原版 `worker_registry` 读 `/proc` 抛错 →
`gui.py` 秒退 `code=1`，wrapper 无限重拉）。

本模块改为**运行时注入**：上游文件一个字节都不改，上游随便更新。

生效方式
--------
`wrapper.py` 给所有 guest Python 进程设 `PYTHONPATH=<ALAS_ROOT>`；本文件旁边
放一个一行 `sitecustomize.py`（`import alasaos_bootstrap`）。Python 启动时
site 机制自动 import sitecustomize → 装上 import hook（Linux fork 的子进程
同样继承）。

为什么用 import hook 而不是直接 setattr
--------------------------------------
`sitecustomize` 在解释器启动极早期执行，此时上游模块**还没被 import**，
拿不到类对象；而且提前 import `module.device.screenshot` 会连带加载
numpy/cv2，拖慢每一个 Python 进程（包括 `uv`、`env_fix` 里的小脚本）。
所以：装一个 meta_path finder，**等目标模块被真正 import 时再注入**。

硬约束
------
1. **绝不抛异常**——sitecustomize 里抛异常会让解释器启动失败。所有注入点
   单独 try/except，失败只记一行 WARN，其余照常。
2. **幂等**——同一 fullname 只注入一次（`_patched` 集合）。
3. **容错**——上游改名/删方法时跳过该点并记 WARN（这意味着"接线断了"，
   要能在日志里看见，而不是静默出错）。
4. **自检**——每次注入完成后 grep 关键接线是否就位，写一行汇总日志，
   便于事后判断"注入到底成没成"。

日志落盘：`<ALAS_ROOT>/log/alasaos_bootstrap.log`（append，含时间戳）。
"""
from __future__ import annotations

import os
import sys
import time
import traceback
from importlib.machinery import PathFinder

__all__ = ['install', 'PATCHERS']

# --------------------------------------------------------------------------
# 日志：刻意写得极轻（sitecustomize 阶段不能依赖上游 logger）
# --------------------------------------------------------------------------

_ALAS_ROOT = os.environ.get('ALASAOS_ALAS_ROOT', '/opt/alas')
_LOG_PATH = os.path.join(_ALAS_ROOT, 'log', 'alasaos_bootstrap.log')


def _log(msg: str) -> None:
    line = f'{time.strftime("%Y-%m-%d %H:%M:%S")} [bootstrap] {msg}\n'
    try:
        os.makedirs(os.path.dirname(_LOG_PATH), exist_ok=True)
        with open(_LOG_PATH, 'a', encoding='utf-8') as f:
            f.write(line)
    except OSError:
        pass


# --------------------------------------------------------------------------
# 目标模块 → 注入函数
# --------------------------------------------------------------------------

def _is_bridge(config) -> bool:
    """桥接模式判据：serial 以 alasaos 开头（与上游 Connection 的判据一致）。"""
    try:
        return str(getattr(config, 'Emulator_Serial', '')).strip().startswith('alasaos')
    except Exception:
        return False


def _patch_screenshot(mod) -> list:
    """Screenshot：挂桥方法 + 往截图分派 dict 塞 'alasaos'。"""
    done = []
    from module.device.method.alasaos import AlasAos
    cls = getattr(mod, 'Screenshot', None)
    if cls is None:
        return done
    for name in ('screenshot_alasaos',):
        fn = getattr(AlasAos, name, None)
        if fn is not None:
            setattr(cls, name, fn)
            done.append(f'Screenshot.{name}')

    prop = cls.__dict__.get('screenshot_methods')
    inner = getattr(prop, 'func', None)
    if inner is not None:
        from module.base.decorator import cached_property

        @cached_property
        def screenshot_methods(self):
            d = inner(self)
            if isinstance(d, dict) and 'alasaos' not in d:
                d['alasaos'] = self.screenshot_alasaos
            return d

        cls.screenshot_methods = screenshot_methods
        done.append('Screenshot.screenshot_methods[alasaos]')
    return done


def _patch_control(mod) -> list:
    """Control：挂桥方法 + 分派 dict + 四个 if/elif 链上的方法包装。

    方法包装统一用 `inspect.signature` 绑定参数名，**不依赖参数位置** ——
    上游改签名只要参数名不变就仍然有效。
    """
    done = []
    import inspect
    from module.device.method.alasaos import AlasAos
    cls = getattr(mod, 'Control', None)
    if cls is None:
        return done

    bridge_methods = (
        'click_alasaos', 'long_click_alasaos', 'swipe_alasaos', 'island_swipe_hold_alasaos',
    )
    for name in bridge_methods:
        fn = getattr(AlasAos, name, None)
        if fn is not None:
            setattr(cls, name, fn)
            done.append(f'Control.{name}')

    # ① 点击走分派 dict（上游 click() 按 Emulator_ControlMethod 取 dict）
    prop = cls.__dict__.get('click_methods')
    inner = getattr(prop, 'func', None)
    if inner is not None:
        from module.base.decorator import cached_property

        @cached_property
        def click_methods(self):
            d = inner(self)
            if isinstance(d, dict) and 'alasaos' not in d:
                d['alasaos'] = self.click_alasaos
            return d

        cls.click_methods = click_methods
        done.append('Control.click_methods[alasaos]')

    # ② 其余四个走 if/elif，包一层：桥接模式走桥，否则原样调上游
    def _ensure_time(v):
        """把 duration 归一到秒（上游这里是 (min, max) 元组）。"""
        try:
            if isinstance(v, (tuple, list)):
                v = sum(v) / len(v) if v else 0.1
            return max(0.1, float(v))
        except Exception:
            return 0.1

    def _wrap(name, bridge_name, build_kwargs):
        orig = getattr(cls, name, None)
        if orig is None:
            _log(f'WARN Control.{name} 不存在（上游改名？），跳过')
            return None
        try:
            sig = inspect.signature(orig)
        except (TypeError, ValueError):
            _log(f'WARN Control.{name} 取签名失败，跳过')
            return None

        def _wrapped(self, *args, **kwargs):
            if _is_bridge(getattr(self, 'config', None)):
                try:
                    bound = sig.bind(self, *args, **kwargs)
                    bound.apply_defaults()
                    return getattr(self, bridge_name)(**build_kwargs(bound.arguments, _ensure_time))
                except Exception as exc:
                    _log(f'WARN Control.{name} 桥分派失败，回退上游：{exc!r}')
            return orig(self, *args, **kwargs)

        _wrapped.__name__ = name
        setattr(cls, name, _wrapped)
        return name

    def _long_click_kwargs(a, et):
        btn = a.get('button')
        x, y = (btn[0], btn[1]) if isinstance(btn, (tuple, list)) else (btn, btn)
        return {'x': x, 'y': y, 'duration': et(a.get('duration', 0.1))}

    def _swipe_kwargs(a, et):
        return {'p1': a.get('p1'), 'p2': a.get('p2'), 'duration': et(a.get('duration', 0.1))}

    def _drag_kwargs(a, et):
        # 桥只有 click/swipe 两个原语：拖拽退化为直线滑动（不支持 shake 抖动）
        return {'p1': a.get('p1'), 'p2': a.get('p2'),
                'duration': et(a.get('hold_duration', a.get('duration', 0.5)))}

    def _island_kwargs(a, et):
        # ⚠️ 桥实现的签名是 (p1, p2, hold_time)，**自己吃毫秒、内部转秒**
        #    （见 alasaos.py 的 island_swipe_hold_alasaos）。这里原样透传，
        #    不要自作聪明换成 duration —— 实测会 TypeError 并静默回退上游。
        return {'p1': a.get('p1'), 'p2': a.get('p2'), 'hold_time': a.get('hold_time')}

    for name, bn, bk in (
        ('long_click', 'long_click_alasaos', _long_click_kwargs),
        ('swipe', 'swipe_alasaos', _swipe_kwargs),
        ('drag', 'swipe_alasaos', _drag_kwargs),
        ('island_swipe_hold', 'island_swipe_hold_alasaos', _island_kwargs),
    ):
        if _wrap(name, bn, bk):
            done.append(f'Control.{name}->{bn}')
    return done


def _patch_app_control(mod) -> list:
    """AppControl：挂桥方法 + 四个方法在桥接模式下改走桥。"""
    done = []
    from module.device.method.alasaos import AlasAos
    cls = getattr(mod, 'AppControl', None)
    if cls is None:
        return done

    for name in ('app_start_alasaos', 'app_stop_alasaos', 'app_current_alasaos',
                 'dump_hierarchy_alasaos'):
        fn = getattr(AlasAos, name, None)
        if fn is not None:
            setattr(cls, name, fn)
            done.append(f'AppControl.{name}')

    for name, bridge_name in (
        ('app_current', 'app_current_alasaos'),
        ('app_start', 'app_start_alasaos'),
        ('app_stop', 'app_stop_alasaos'),
        ('dump_hierarchy', 'dump_hierarchy_alasaos'),
    ):
        orig = getattr(cls, name, None)
        if orig is None:
            _log(f'WARN AppControl.{name} 不存在（上游改名？），跳过')
            continue

        # ⚠️ 必须用 keyword-only 默认参数固化 orig/bridge_name：
        # 否则循环变量的**晚绑定**会让所有包装都指向最后一个值。
        def _wrapped(self, *args, _orig=orig, _bn=bridge_name, **kwargs):
            if _is_bridge(getattr(self, 'config', None)):
                try:
                    # 上游 app_current/app_start/app_stop/dump_hierarchy 均**无参**，
                    # 桥实现带默认值，直接调用即可。
                    return getattr(self, _bn)()
                except Exception as exc:
                    _log(f'WARN AppControl.{_bn} 调用失败，回退上游：{exc!r}')
            return _orig(self, *args, **kwargs)

        _wrapped.__name__ = name
        setattr(cls, name, _wrapped)
        done.append(f'AppControl.{name}->{bridge_name}')
    return done


def _patch_connection(mod) -> list:
    """Connection.__init__：桥接模式提前走父类 + 自行收尾，跳过 adb 设备检测。

    上游 `Connection.__init__` 在 `super().__init__()` 之后会跑
    detect_device / adb_connect / detect_package —— 桥接模式全都不需要。
    注入无法"截断"上游方法，故桥接模式直接走父类并自行收尾（这几步本来就是
    上游为 adb 设备准备的）。
    """
    done = []
    cls = getattr(mod, 'Connection', None)
    ca_cls = getattr(mod, 'ConnectionAttr', None)
    if cls is None or ca_cls is None:
        _log('WARN connection：Connection/ConnectionAttr 缺失，跳过')
        return done
    set_server = getattr(mod, 'set_server', None)
    logger = getattr(mod, 'logger', None)
    orig_init = cls.__init__

    def _init(self, config=None, *args, **kwargs):
        cfg = config if config is not None else kwargs.get('config')
        if not _is_bridge(cfg):
            return orig_init(self, config, *args, **kwargs)
        ca_cls.__init__(self, config)
        try:
            self.package = self.config.Emulator_PackageName
            if self.package == 'auto':
                self.package = 'com.bilibili.azurlane'
            if set_server is not None:
                set_server(self.package)
            if logger is not None:
                logger.attr('应用包名', self.package)
                logger.attr('服务器', self.config.SERVER)
                logger.info('AlasAos 桥接模式：跳过 adb 设备检测（运行时注入）')
        except Exception as exc:
            _log(f'WARN connection 桥接收尾出错：{exc!r}')
        return None

    _init.__name__ = '__init__'
    cls.__init__ = _init
    done.append('Connection.__init__[bridge short-circuit]')
    return done


def _patch_connection_attr(mod) -> list:
    """ConnectionAttr：桥接模式不碰 adb —— 挡住「自动下载 platform-tools」。

    上游 `__init__` 里 `logger.attr('ADB路径', self.adb_binary)` 会走
    `adb_binary`（cached_property），找不到 adb 就**自动下载 platform-tools**；
    Android 上 dl.google.com 不可达 → BadZipFile → 设备初始化直接崩
    （真机实证：白等 123 秒后失败）。

    注入手法：在 `__init__` 之前**抢先往 `self.__dict__` 塞 adb_binary** ——
    cached_property 见实例字典已有值即不再调用原函数，下载路径自然不触发。
    """
    done = []
    cls = getattr(mod, 'ConnectionAttr', None)
    if cls is None:
        _log('WARN connection_attr：ConnectionAttr 缺失，跳过')
        return done
    orig_init = cls.__init__

    def _init(self, config=None, *args, **kwargs):
        cfg = config if config is not None else kwargs.get('config')
        if _is_bridge(cfg):
            try:
                self.__dict__['adb_binary'] = ''
            except Exception:
                pass
        return orig_init(self, config, *args, **kwargs)

    _init.__name__ = '__init__'
    cls.__init__ = _init
    done.append('ConnectionAttr.__init__[skip adb_binary download]')

    prop = cls.__dict__.get('adb_binary')
    inner = getattr(prop, 'func', None)
    if inner is not None:
        from module.base.decorator import cached_property

        @cached_property
        def adb_binary(self):
            # 幂等防护：即便别处访问本属性，桥接模式也不做探测/下载
            if _is_bridge(getattr(self, 'config', None)):
                return ''
            return inner(self)

        cls.adb_binary = adb_binary
        done.append('ConnectionAttr.adb_binary[bridge guard]')
    return done


def _patch_worker_registry(mod) -> list:
    """worker_registry：Android 读不到 /proc → 降级为「无法确认」，**不要 raise**。

    上游在两处直接 raise：
      - `_process_created_at()`  → claim_owner 未捕获 → WebUI 启动即炸
      - `process_matches()`      → 保守返回 True → 误判「旧实例还在」→ 拒绝启动
    真机实证：gui.py `exited code=1 uptime=1s` 无限重拉（2026-09-25 事故）。
    """
    done = []
    orig_pca = getattr(mod, '_process_created_at', None)
    if orig_pca is not None:
        def _process_created_at(pid):
            try:
                return orig_pca(pid)
            except Exception:
                # 降级为「登记时刻」；本进程要顺手缓存（沿用上游的模块级变量语义）
                value = time.time()
                try:
                    if pid == os.getpid():
                        mod._self_created_at = value
                except Exception:
                    pass
                return value

        _process_created_at.__name__ = '_process_created_at'
        mod._process_created_at = _process_created_at
        done.append('worker_registry._process_created_at[degrade]')
    else:
        _log('WARN worker_registry：_process_created_at 缺失，跳过')

    orig_pm = getattr(mod, 'process_matches', None)
    if orig_pm is not None:
        def process_matches(record):
            try:
                return orig_pm(record)
            except Exception:
                return None  # 无法确认 → 上层按「非存活」处理

        process_matches.__name__ = 'process_matches'
        mod.process_matches = process_matches
        done.append('worker_registry.process_matches[degrade→None]')
    else:
        _log('WARN worker_registry：process_matches 缺失，跳过')
    return done


_PATCHERS = {
    'module.device.screenshot': _patch_screenshot,
    'module.device.control': _patch_control,
    'module.device.app_control': _patch_app_control,
    'module.device.connection': _patch_connection,
    'module.device.connection_attr': _patch_connection_attr,
    'module.webui.worker_registry': _patch_worker_registry,
}


# --------------------------------------------------------------------------
# import hook：等目标模块被真正 import 时再注入
# --------------------------------------------------------------------------

class _WrapLoader:
    """包装真实 loader：先正常执行模块，再注入。"""

    def __init__(self, loader, fullname: str):
        self._loader = loader
        self._fullname = fullname

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        self._loader.exec_module(module)
        _run_patch(self._fullname, module)

    def __getattr__(self, item):
        return getattr(self._loader, item)


class _PatchingFinder:
    def __init__(self):
        self.patched = set()

    def find_spec(self, fullname, path=None, target=None):
        if fullname not in _PATCHERS or fullname in self.patched:
            return None
        try:
            # 直接用 PathFinder 查（不遍历 meta_path，避免自我递归）
            spec = PathFinder.find_spec(fullname, path)
        except Exception as exc:
            _log(f'WARN find_spec {fullname} 失败：{exc!r}')
            return None
        if spec is None or spec.loader is None:
            return None
        spec.loader = _WrapLoader(spec.loader, fullname)
        return spec


_FINDER = None


def _run_patch(fullname: str, module) -> None:
    fn = _PATCHERS.get(fullname)
    if fn is None:
        return
    try:
        done = fn(module) or []
    except Exception:
        _log(f'FAIL {fullname} 注入异常：{traceback.format_exc(limit=4)}')
        done = []
    if _FINDER is not None:
        try:
            _FINDER.patched.add(fullname)
        except Exception:
            pass
    if done:
        _log(f'OK {fullname}（{len(done)} 处）：' + ', '.join(done))
    else:
        _log(f'WARN {fullname} 注入 0 处 —— 上游结构可能变了，接线未生效')


def install() -> None:
    """装上 finder（幂等）。绝不抛异常。"""
    global _FINDER
    if _FINDER is not None:
        return
    try:
        _FINDER = _PatchingFinder()
        sys.meta_path.insert(0, _FINDER)
        _log('installed：meta_path finder 就位，等待上游模块被 import')
    except Exception:
        _log(f'FAIL install：{traceback.format_exc(limit=4)}')


# import 本模块即生效（sitecustomize 只需一行 `import alasaos_bootstrap`）
if not os.environ.get('ALASAOS_BOOTSTRAP_NO_AUTOINSTALL'):
    install()

