"""Сборка C-моста _exteraless_bridge.

Запуск (из python/bridge, компилятор в PATH или MSVC, находимый setuptools):

    python setup.py build_ext --inplace

Требования: CPython 3.12+, setuptools; на Windows — MSVC Build Tools
(исходник в UTF-8, компилируем с /utf-8). Подробный контракт колбэков —
в шапке _exteraless_bridge.c.
"""

import sys

from setuptools import Extension, setup

is_msvc = sys.platform == "win32"
compile_args = ["/utf-8"] if is_msvc else ["-Wall"]

setup(
    name="exteraless-bridge",
    version="0.1.0",
    description="exteraless virtual-java C bridge (stage 2)",
    ext_modules=[
        Extension(
            "_exteraless_bridge",
            sources=["_exteraless_bridge.c"],
            extra_compile_args=compile_args,
            py_limited_api=False,
        )
    ],
)
