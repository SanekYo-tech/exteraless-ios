"""Импортер virtual-java: перехватывает `import com.* / org.* / android.*`.

Модули-пакеты Java создаются на лету; `from com.x import Y` отдаёт
прокси-класс, `import com.x.Y` — модуль-обёртку, делегирующую классу.
Алиасы (com.exteragram.* -> app.exteraless.*) применяет hosts-скрипт
class_aliases.py из vendored SDK, если он есть.
"""

import importlib.abc
import importlib.util
import os
import sys
import types

from .proxy import get_class, _is_class_name

JAVA_ROOTS = ("java", "javax", "android", "androidx", "org", "com",
              "kotlin", "dalvik")

# Chaquopy-модули, которых на iOS-мосте нет. Отказ честный (ImportError),
# как отсутствие класса — SDK exteraless рассчитывает на graceful-деградацию.
DENY_MODULES = ("java.android",)

_ALIASES_PATH_CANDIDATES = (
    os.path.join("third_party", "exteraless-android", "TMessagesProj",
                 "src", "main", "python", "extera_utils", "class_aliases.py"),
)


def _load_aliases():
    """class_aliases.py из vendored SDK (если есть) — для резолва имён."""
    for candidate in _ALIASES_PATH_CANDIDATES:
        if os.path.isfile(candidate):
            spec = importlib.util.spec_from_file_location(
                "virtualjava_class_aliases", candidate)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
                return module
            except Exception:
                return None
    return None


class _State:
    backend = None
    aliases = None
    installed = False


def resolve_name(fqcn: str) -> str:
    if _State.aliases is not None:
        try:
            return _State.aliases.resolve(fqcn)
        except Exception:
            return fqcn
    return fqcn


class JavaPackage(types.ModuleType):
    """Пакет Java: `pkg.ClassName` -> прокси, `pkg.sub` -> подпакет."""

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        backend = _State.backend
        if backend is None:
            raise ImportError("virtualjava не установлен (install())")
        # Chaquopy-специфика: функции и типы модуля java.
        if self.__name__ == "java":
            if name in ("jclass", "jarray", "cast", "dynamic_proxy",
                        "Override", "jint", "jlong", "jfloat", "jdouble",
                        "jboolean", "jbyte", "jshort", "jchar", "jvoid",
                        "jpackage", "findClass"):
                return _chaquopy_builtin(name, backend)
            if name == "chaquopy":
                module = _chaquopy_module()
                sys.modules.setdefault("java.chaquopy", module)
                return module
        full = f"{self.__name__}.{name}"
        if _is_class_name(name):
            return get_class(resolve_name(full), backend)
        # Подпакет: создаём лениво и регистрируем как модуль.
        sub = JavaPackage(full)
        sub.__path__ = []
        sys.modules[full] = sub
        return sub


def _chaquopy_builtin(name, backend):
    """java.jclass / jint / dynamic_proxy — точки входа reflection у плагинов."""
    if name == "jclass":
        def jclass(fqcn):
            return get_class(resolve_name(fqcn), backend)
        return jclass
    if name == "dynamic_proxy":
        from .proxy import dynamic_proxy
        return dynamic_proxy
    if name == "Override":
        return lambda func: func

    def _generic(*args, **kwargs):
        # jint(x)/jlong(x) — приведение типа; в прокси-мире — identity.
        if len(args) == 1:
            return args[0]
        from .backend import _Universal
        return _Universal(f"java.{name}({args!r})", backend)
    return _generic


# --- java.chaquopy: API форка exteraless-chaquopy (security-гейты) ---------
# На iOS эти хуки реализует C-мост: политика reflection, guard на вызовы,
# фолбэк для ненайденных классов. Здесь — честная эмуляция для симуляции.

_CHAQUOPY_STATE = {
    "reflection_policy": None,
    "call_fallback": None,
    "sealed": False,
}


def _chaquopy_module():
    import types as _types
    mod = _types.ModuleType("java.chaquopy")
    mod.__path__ = []

    def set_reflection_policy(fn):
        if _CHAQUOPY_STATE["sealed"]:
            raise RuntimeError("reflection policy sealed")
        _CHAQUOPY_STATE["reflection_policy"] = fn

    def get_reflection_policy():
        return _CHAQUOPY_STATE["reflection_policy"]

    def seal_reflection_policy():
        _CHAQUOPY_STATE["sealed"] = True

    def set_call_fallback(fn):
        _CHAQUOPY_STATE["call_fallback"] = fn

    mod.set_reflection_policy = set_reflection_policy
    mod.get_reflection_policy = get_reflection_policy
    mod.seal_reflection_policy = seal_reflection_policy
    mod.set_call_fallback = set_call_fallback

    from .proxy import JavaClass, dynamic_proxy  # noqa: F401

    class GuardedMethod:  # noqa: D401 — эмуляция GuardedMethod chaquopy
        def __init__(self, *args, **kwargs):
            pass

        def __getattr__(self, name):
            from .backend import _Universal
            return _Universal(f"GuardedMethod.{name}", None)

    class ProxyClass:
        def __init__(self, *args, **kwargs):
            pass

    mod.GuardedMethod = GuardedMethod
    mod.ProxyClass = ProxyClass
    mod.JavaClass = JavaClass
    mod.dynamic_proxy = dynamic_proxy
    mod.Override = lambda func: func
    return mod


class JavaClassModule(types.ModuleType):
    """`import com.x.Y`: модуль, делегирующий атрибуты прокси-классу."""

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        proxy = get_class(resolve_name(self.__name__), _State.backend)
        return getattr(proxy, name)


class _Loader(importlib.abc.Loader):

    def create_module(self, spec):
        if spec.name == "java.chaquopy":
            module = _chaquopy_module()
            module.__loader__ = self
            return module
        if _is_class_name(spec.name.rsplit(".", 1)[-1]):
            # Класс как модуль: __path__ обязателен, чтобы работали
            # цепочки вида Components.Premium.StarParticlesView
            # (Java-пакеты бывают с заглавных букв).
            module = JavaClassModule(spec.name)
            module.__path__ = []
        else:
            module = JavaPackage(spec.name)
            module.__path__ = []
        module.__loader__ = self
        return module

    def exec_module(self, module):
        return None


class _Finder(importlib.abc.MetaPathFinder):

    def find_spec(self, fullname, path=None, target=None):
        root = fullname.split(".", 1)[0]
        if root not in JAVA_ROOTS:
            return None
        if fullname in DENY_MODULES or any(
                fullname.startswith(denied + ".")
                for denied in DENY_MODULES):
            return None
        return importlib.util.spec_from_loader(fullname, _Loader())


_FINDER = _Finder()


def install(backend):
    """Включить virtual-java в текущем интерпретаторе с данным бэкендом."""
    _State.backend = backend
    if _State.aliases is None:
        _State.aliases = _load_aliases()
    if not _State.installed:
        sys.meta_path.insert(0, _FINDER)
        _State.installed = True


def uninstall():
    """Выключить (для тестов)."""
    if _State.installed:
        try:
            sys.meta_path.remove(_FINDER)
        except ValueError:
            pass
        _State.installed = False
    _State.backend = None
    for name in list(sys.modules):
        if name.split(".", 1)[0] in JAVA_ROOTS:
            del sys.modules[name]


def reset_class_cache():
    """Сброс кэша прокси-классов (смена бэкенда в тестах)."""
    from .proxy import reset_caches
    reset_caches()
