"""Прокси-классы virtual-java.

JavaClass — метакласс-обёртка над FQCN: атрибуты класса -> статические
члены или вложенные классы; вызов класса -> конструктор; атрибуты
экземпляра -> члены объекта. Никакой предметной логики — только
маршрутизация в бэкенд; «поле или метод» решает бэкенд (member_kind),
и ответ кэшируется.
"""

_KIND_CACHE = {}


def _is_class_name(name: str) -> bool:
    return bool(name) and name[0].isupper()


def _member_kind(backend, fqcn: str, name: str) -> str:
    key = (id(backend), fqcn, name)
    kind = _KIND_CACHE.get(key)
    if kind is None:
        kind = backend.member_kind(fqcn, name)
        _KIND_CACHE[key] = kind
    return kind


class JavaClass(type):
    """Метакласс прокси: `X.member` и `X()`."""

    def __getattr__(cls, name):
        fqcn = cls.__name__
        backend = cls._backend
        if _is_class_name(name):
            # Вложенный класс: Outer$Inner доступен как Outer.Inner.
            return get_class(f"{fqcn}${name}", backend)
        kind = _member_kind(backend, fqcn, name)
        if kind == "field":
            return backend.get(fqcn, name)
        return _StaticMember(fqcn, name, backend)

    def __setattr__(cls, name, value):
        if name.startswith("__") and name.endswith("__"):
            super().__setattr__(name, value)
            return
        cls._backend.set(cls.__name__, name, value)

    def __call__(cls, *args, **kwargs):
        return cls._backend.construct(cls.__name__, args)

    def __repr__(cls):
        return f"<JavaClass {cls.__name__}>"

    def __instancecheck__(cls, instance):
        # isinstance(x, ProxyClass) — по факту fqcn хоста.
        target = getattr(instance, "_fqcn", None)
        if target is None:
            return False
        return target == cls.__name__ or cls._backend.class_exists(target)


class DynamicProxyMeta(JavaClass):
    """Классы-реализации Java-интерфейсов (`dynamic_proxy(I)`).

    Отличие от JavaClass: создание инстанса — обычное Python-создание,
    а не вызов конструктора Java: это Python-класс, реализующий
    интерфейс, хост маршалит его как callback.
    """

    def __call__(cls, *args, **kwargs):
        return type.__call__(cls, *args, **kwargs)


def dynamic_proxy(base):
    """java.chaquopy.dynamic_proxy: обёртка для реализации Java-интерфейсов.

    class MyTask(dynamic_proxy(Runnable)):
        def run(self): ...
    """
    name = f"DynamicProxy[{getattr(base, '__name__', base)}]"
    if isinstance(base, type) and isinstance(type(base), JavaClass):
        return DynamicProxyMeta(name, (base,),
                                {"__module__": "java.chaquopy",
                                 "__qualname__": name})
    # Стаб-класс или другой тип: наследуем как есть, обычным классом.
    return type(name, (base,) if isinstance(base, type) else (),
                {"__module__": "java.chaquopy"})


class _StaticMember:
    """Статический член класса: поле (значение) и метод (вызов) одновременно."""

    __slots__ = ("_fqcn", "_name", "_backend")

    def __init__(self, fqcn, name, backend):
        self._fqcn = fqcn
        self._name = name
        self._backend = backend

    def __call__(self, *args, **kwargs):
        return self._backend.call(self._fqcn, self._name, args, kwargs)

    def __getattr__(self, name):
        # Обращение к члену как к объекту (редко, но бывает).
        return self._backend.get(self._fqcn, f"{self._name}.{name}")

    def __repr__(self):
        return f"<static {self._fqcn}#{self._name}>"


class JavaInstance:
    """Объект Java: `obj.member` -> поле или метод хоста."""

    __slots__ = ("_fqcn", "_backend")

    def __init__(self, fqcn, backend):
        object.__setattr__(self, "_fqcn", fqcn)
        object.__setattr__(self, "_backend", backend)

    def __getattr__(self, name):
        backend = object.__getattribute__(self, "_backend")
        fqcn = object.__getattribute__(self, "_fqcn")
        if _is_class_name(name):
            # Обращение к внутреннему классу через инстанс внешнего.
            return get_class(f"{fqcn}${name}", backend)
        kind = _member_kind(backend, fqcn, name)
        if kind == "field":
            return backend.get_instance(self, name)
        return _InstanceMember(self, name, backend)

    def __setattr__(self, name, value):
        object.__getattribute__(self, "_backend").set_instance(self, name, value)

    def __call__(self, *args, **kwargs):
        # Java-объекты, вызываемые как Runnable/Callable.
        backend = object.__getattribute__(self, "_backend")
        return backend.call_instance(self, "__call__", args, kwargs)

    def __repr__(self):
        return f"<Java {object.__getattribute__(self, '_fqcn')}>"

    def __str__(self):
        backend = object.__getattribute__(self, "_backend")
        try:
            return str(backend.call_instance(self, "toString", (), {}))
        except Exception:
            return f"<Java {object.__getattribute__(self, '_fqcn')}>"

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)


class _InstanceMember:
    __slots__ = ("_instance", "_name", "_backend")

    def __init__(self, instance, name, backend):
        self._instance = instance
        self._name = name
        self._backend = backend

    def __call__(self, *args, **kwargs):
        return self._backend.call_instance(
            self._instance, self._name, args, kwargs)

    def __getattr__(self, name):
        return self._backend.get_instance(
            self._instance, f"{self._name}.{name}")

    def __repr__(self):
        return f"<member {self._name}>"


_CLASS_CACHE = {}


def get_class(fqcn: str, backend):
    """Прокси-класс по FQCN (с кэшем; бэкенд один на процесс)."""
    cached = _CLASS_CACHE.get(fqcn)
    if cached is not None:
        return cached
    cls = JavaClass(fqcn, (JavaInstance,), {
        "__name__": fqcn,
        "_backend": backend,
        "__qualname__": fqcn,
    })
    _CLASS_CACHE[fqcn] = cls
    return cls


def reset_caches():
    """Сброс кэшей прокси (смена бэкенда в тестах)."""
    _CLASS_CACHE.clear()
    _KIND_CACHE.clear()
