"""Бэкенд virtual-java: куда уходят вызовы прокси.

Backend — протокол, который на iOS реализует C-мост `_exteraless_bridge`
(Swift-сторона знает настоящую поверхность классов), а на десктопе —
MockBackend для тестов и симуляции.

Методы:
    construct(fqcn, args)          — new X(...)
    call(fqcn, member, args, kw)   — статический вызов X.member(...)
    call_instance(obj, member, args, kw) — obj.member(...)
    get(fqcn, member)              — чтение статического поля
    get_instance(obj, member)      — чтение поля объекта
    set(fqcn, member, value)       — запись статического поля
    set_instance(obj, member, value)
    member_kind(fqcn, member)      — "field" | "method" | "unknown"
    class_exists(fqcn) -> bool
"""

import json
import os
from typing import Any

from .proxy import JavaInstance


class JavaMemberError(Exception):
    """Бэкенд отказал: класса/члена нет на стороне хоста."""


class Backend:
    """Протокол бэкенда; реализуется мостом (iOS) или моком (десктоп)."""

    def construct(self, fqcn: str, args: tuple) -> Any:
        raise NotImplementedError

    def call(self, fqcn: str, member: str,
             args: tuple, kwargs: dict) -> Any:
        raise NotImplementedError

    def call_instance(self, instance: Any, member: str,
                      args: tuple, kwargs: dict) -> Any:
        raise NotImplementedError

    def get(self, fqcn: str, member: str) -> Any:
        raise NotImplementedError

    def get_instance(self, instance: Any, member: str) -> Any:
        raise NotImplementedError

    def set(self, fqcn: str, member: str, value: Any) -> None:
        raise NotImplementedError

    def set_instance(self, instance: Any, member: str, value: Any) -> None:
        raise NotImplementedError

    def member_kind(self, fqcn: str, member: str) -> str:
        """Поле или метод? "unknown" — разбирайся на вызове (permissive)."""
        return "unknown"

    def class_exists(self, fqcn: str) -> bool:
        return True


class CallRecord:
    __slots__ = ("kind", "target", "member", "args")

    def __init__(self, kind, target, member, args=()):
        self.kind = kind
        self.target = target
        self.member = member
        self.args = args

    def __repr__(self):
        return f"<Call {self.kind} {self.target}#{self.member}>"


_MANIFEST_ENV = "EXTERALESS_MANIFEST"
_MANIFEST_DEFAULT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))),
    "build", "compat", "manifest.json")


class MockBackend(Backend):
    """Десктоп-мок с поверхностью классов из манифеста совместимости.

    member_kind отвечает по parsed-полям Java-классов (javaapi), поэтому
    симуляция различает `Theme.key_windowBackgroundWhiteBlackText` (поле)
    и `Theme.getColor(...)` (метод) — как настоящий мост на Swift.
    """

    def __init__(self, manifest_path=None):
        self.calls = []
        self.missing_classes = set()
        self.missing_members = set()
        self._fields = {}
        path = manifest_path or os.environ.get(
            _MANIFEST_ENV, _MANIFEST_DEFAULT)
        if path and os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                manifest = json.load(fh)
            for fqcn, entry in manifest.get("classes", {}).items():
                declared = entry.get("declared")
                if declared:
                    self._fields[fqcn] = frozenset(declared.get("fields", []))

    def _note(self, kind, target, member, args=()):
        self.calls.append(CallRecord(kind, target, member, args))

    def construct(self, fqcn, args):
        if not self.class_exists(fqcn):
            self.missing_classes.add(fqcn)
            raise JavaMemberError(f"no class {fqcn}")
        self._note("new", fqcn, "<init>", args)
        return JavaInstance(fqcn, self)

    def call(self, fqcn, member, args, kwargs):
        if not self.class_exists(fqcn):
            self.missing_classes.add(fqcn)
            raise JavaMemberError(f"no class {fqcn}")
        self._note("static", fqcn, member, args)
        return _Universal(f"result:{fqcn}#{member}", self)

    def call_instance(self, instance, member, args, kwargs):
        self._note("instance", _target_of(instance), member, args)
        return _Universal(f"result:{_target_of(instance)}#{member}", self)

    def get(self, fqcn, member):
        self._note("sfield", fqcn, member)
        return _Universal(f"field:{fqcn}#{member}", self)

    def get_instance(self, instance, member):
        self._note("ifield", _target_of(instance), member)
        return _Universal(f"field:{_target_of(instance)}#{member}", self)

    def set(self, fqcn, member, value):
        self._note("sset", fqcn, member, (value,))
        return None

    def set_instance(self, instance, member, value):
        self._note("iset", _target_of(instance), member, (value,))
        return None

    def member_kind(self, fqcn, member):
        fields = self._fields.get(fqcn)
        if fields is not None:
            if member in fields:
                return "field"
            return "method"
        return "unknown"

    def class_exists(self, fqcn: str) -> bool:
        return True


class _Universal:
    """Перmissive результат мока: любой атрибут вызываем и не падает."""

    __slots__ = ("_target", "_backend")

    def __init__(self, target: str, backend):
        object.__setattr__(self, "_target", target)
        object.__setattr__(self, "_backend", backend)

    def __getattr__(self, name):
        backend = object.__getattribute__(self, "_backend")
        target = object.__getattribute__(self, "_target")
        return _UniversalMethod(backend, target, name)

    def __call__(self, *args, **kwargs):
        return _Universal(f"call:{object.__getattribute__(self, '_target')}",
                          object.__getattribute__(self, "_backend"))

    def __repr__(self):
        return f"<mock {object.__getattribute__(self, '_target')}>"

    def __str__(self):
        return object.__getattribute__(self, "_target")

    def __bool__(self):
        return True

    def __iter__(self):
        return iter(())

    def __getitem__(self, key):
        return _Universal(
            f"{object.__getattribute__(self, '_target')}[{key!r}]",
            object.__getattribute__(self, "_backend"))

    def __int__(self):
        return 0

    def __float__(self):
        return 0.0

    def __len__(self):
        return 0


class _UniversalMethod:
    __slots__ = ("_backend", "_target", "_name")

    def __init__(self, backend, target, name):
        self._backend = backend
        self._target = target
        self._name = name

    def __call__(self, *args, **kwargs):
        self._backend._note("chain", self._target, self._name, args)
        return _Universal(f"{self._target}#{self._name}", self._backend)


def _target_of(instance) -> str:
    return getattr(instance, "_fqcn", None) or type(instance).__name__
