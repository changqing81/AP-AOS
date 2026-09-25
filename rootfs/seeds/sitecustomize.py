# AlasAos · 桥接注入入口
#
# 由构建期放到 PYTHONPATH 可见处（wrapper.py 会把 <ALAS_ROOT> 加进 PYTHONPATH）。
# Python 启动时 site 机制自动 import 本模块 —— 每个 guest Python 进程（含 fork
# 出来的子进程）都会执行，从而装上 alasaos_bootstrap 的 import hook。
#
# ⚠️ 本文件必须**极简且绝不抛异常**：sitecustomize 抛异常会导致解释器启动失败
#    （而它会跑在被 `uv` / `env_fix` 拉起的小脚本里）。容错交给 alasaos_bootstrap。
try:
    import alasaos_bootstrap  # noqa: F401
except Exception:
    pass
