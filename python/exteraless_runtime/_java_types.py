"""Small, concrete Java ADTs/reflection over Python ports; no unknown-member defaults."""

import inspect
from collections.abc import ItemsView, KeysView, Mapping, MutableSequence, MutableSet, ValuesView
import os
import time
import uuid
from urllib.parse import parse_qs, urlsplit


class _ClassAccess:
    def __get__(self, instance, owner):
        return lambda: ClassInfo(owner, instance)


class Object:
    getClass = _ClassAccess()

    def equals(self, other):
        return self == other

    def hashCode(self):
        return hash(self)

    def toString(self):
        return str(self)


class Field(Object):
    def __init__(self, owner, name):
        self.owner, self.name = owner, name

    def getName(self):
        return self.name

    def setAccessible(self, accessible):
        return None  # Python ports have no JVM access checks.

    def get(self, obj):
        return getattr(self.owner if obj is None else obj, self.name)

    def set(self, obj, value):
        setattr(self.owner if obj is None else obj, self.name, value)


class Method(Field):
    def invoke(self, obj, *args):
        if len(args) == 1 and isinstance(args[0], (list, tuple)):
            args = tuple(args[0])
        return getattr(self.owner if obj is None else obj, self.name)(*args)

    def getParameterTypes(self):
        fn = getattr(self.owner, self.name)
        params = list(inspect.signature(fn).parameters.values())
        if params and params[0].name in ("self", "cls"):
            params.pop(0)
        return ArrayList(ClassInfo(p.annotation if isinstance(p.annotation, type) else Object) for p in params)

    def getReturnType(self):
        annotation = inspect.signature(getattr(self.owner, self.name)).return_annotation
        return ClassInfo(annotation if isinstance(annotation, type) else Object)


class ClassInfo(Object):
    def __init__(self, cls, instance=None):
        self.cls, self.instance = cls, instance

    @staticmethod
    def forName(name):
        from virtualjava import get_registered, JavaMemberError
        found = get_registered(str(name))
        if found is None:
            raise JavaMemberError(f"no reflected Python port for {name}")
        return ClassInfo(found)

    def getName(self):
        return {bool: "boolean", int: "int", float: "double", type(None): "void"}.get(
            self.cls, getattr(self.cls, "_fqcn", self.cls.__name__))

    def getSimpleName(self):
        return self.getName().rsplit(".", 1)[-1].rsplit("$", 1)[-1]

    def getDeclaredFields(self):
        names = set(getattr(self.cls, "__annotations__", {}))
        names.update(name for name, value in vars(self.cls).items()
                     if not name.startswith("__") and not callable(value) and not isinstance(value, (classmethod, staticmethod)))
        if self.instance is not None:
            names.update(vars(self.instance))
        return ArrayList(Field(self.cls, name) for name in sorted(names))

    def getDeclaredField(self, name):
        for field in self.getDeclaredFields():
            if field.name == name:
                return field
        raise AttributeError(name)

    def getDeclaredMethods(self):
        return ArrayList(Method(self.cls, name) for name in vars(self.cls)
                         if not name.startswith("_") and callable(getattr(self.cls, name)))

    def getMethods(self):
        return ArrayList(Method(self.cls, name) for name in dir(self.cls)
                         if not name.startswith("_") and callable(getattr(self.cls, name)))

    def getDeclaredMethod(self, name, *types):
        if not callable(getattr(self.cls, name, None)):
            raise AttributeError(name)
        return Method(self.cls, name)

    getMethod = getDeclaredMethod

    def getSuperclass(self):
        base = self.cls.__base__
        return ClassInfo(base) if base is not None and base is not object else None

    def isInstance(self, value):
        return isinstance(value, self.cls)

    def newInstance(self):
        return self.cls()


class Iterator(Object):
    def __init__(self, values):
        self.values, self.index = list(values), 0

    def hasNext(self):
        return self.index < len(self.values)

    def next(self):
        if not self.hasNext():
            raise StopIteration
        value = self.values[self.index]
        self.index += 1
        return value


class ArrayList(list, Object):
    def __init__(self, values=()):
        super().__init__(() if type(values) is int else values)

    def add(self, *args):
        if len(args) == 1:
            self.append(args[0])
            return True
        if len(args) == 2:
            self.insert(int(args[0]), args[1])
            return None
        raise TypeError("add(value) or add(index, value)")

    def addAll(self, values):
        values = list(values)
        self.extend(values)
        return bool(values)

    def get(self, index):
        if not 0 <= index < len(self):
            raise IndexError(index)
        return self[index]

    def set(self, index, value):
        previous = self.get(index)
        self[index] = value
        return previous

    def remove(self, value):
        if type(value) is int:
            previous = self.get(value)
            del self[value]
            return previous
        try:
            super().remove(value)
            return True
        except ValueError:
            return False

    def size(self): return len(self)
    def isEmpty(self): return not self
    def contains(self, value): return value in self
    def indexOf(self, value): return self.index(value) if value in self else -1
    def toArray(self): return list(self)
    def iterator(self): return Iterator(self)
    def subList(self, start, end): return ListView(self, start, end)


class ListView(MutableSequence, Object):
    def __init__(self, parent, start=0, end=None, readonly=False):
        if not 0 <= start <= (len(parent) if end is None else end) <= len(parent): raise IndexError((start, end))
        self.parent, self.start, self.end, self.readonly = parent, start, end, readonly
        self.expected = len(parent) if end is not None else None
    def _check(self):
        if self.expected is not None and self.expected != len(self.parent):
            raise RuntimeError("parent list structurally modified outside the view")
    def __len__(self):
        self._check()
        return (len(self.parent) if self.end is None else self.end) - self.start
    def __getitem__(self, index):
        if isinstance(index, slice): return list(self)[index]
        if index < 0: index += len(self)
        if not 0 <= index < len(self): raise IndexError(index)
        return self.parent[self.start + index]
    def __setitem__(self, index, value):
        if self.readonly: raise TypeError("read-only list")
        if index < 0: index += len(self)
        self[index]
        self.parent[self.start + index] = value
    def __delitem__(self, index):
        if self.readonly: raise TypeError("read-only list")
        if index < 0: index += len(self)
        self[index]
        del self.parent[self.start + index]
        if self.end is not None: self.end -= 1; self.expected -= 1
    def insert(self, index, value):
        if self.readonly: raise TypeError("read-only list")
        if not 0 <= index <= len(self): raise IndexError(index)
        self.parent.insert(self.start + index, value)
        if self.end is not None: self.end += 1; self.expected += 1
    def get(self, index):
        if not 0 <= index < len(self): raise IndexError(index)
        return self[index]
    def set(self, index, value):
        previous = self.get(index)
        self[index] = value
        return previous
    def add(self, value): self.append(value); return True
    def size(self): return len(self)
    def isEmpty(self): return not self
    def iterator(self): return Iterator(self)
    def toArray(self): return list(self)


def _int32(value): return (value + 2 ** 31) % 2 ** 32 - 2 ** 31


def _java_equals(left, right):
    # Keep Python numeric operators/unboxing intact. Java collections use the
    # boxed value's declared equality, including when one operand is unboxed.
    if isinstance(left, (Integer, Boolean)) or isinstance(right, (Integer, Boolean)):
        return type(left) is type(right) and left.equals(right)
    if isinstance(left, Object): return bool(left.equals(right))
    if isinstance(right, Object): return bool(right.equals(left))
    return left == right


def _java_hash(value):
    if value is None: return 0
    if isinstance(value, str): return String(value).hashCode()
    if isinstance(value, Object): return value.hashCode()
    return hash(value)


class _JavaKey:
    """Internal equality domain, never a replacement for a public scalar value."""
    __slots__ = ("value",)
    def __init__(self, value): self.value = value
    def __hash__(self): return _java_hash(self.value)
    def __eq__(self, other): return isinstance(other, _JavaKey) and _java_equals(self.value, other.value)
    def __repr__(self): return repr(self.value)
    def __str__(self): return str(self.value)


def _map_key(value):
    # String-key dict storage is also the existing C/JSON object transport.
    return value if isinstance(value, str) else _JavaKey(value)


def _public_key(value): return value.value if isinstance(value, _JavaKey) else value


_MISSING_KEY = object()


class Entry(Object):
    def __init__(self, mapping, key): self.mapping, self.key = mapping, key
    def getKey(self): return self.key
    def getValue(self): return self.mapping[self.key]
    def setValue(self, value):
        if self.key not in self.mapping: raise KeyError("HashMap.Entry.setValue: entry was removed")
        return self.mapping.put(self.key, value)
    def equals(self, other):
        return (isinstance(other, Entry) and _java_equals(self.key, other.key)
                and _java_equals(self.getValue(), other.getValue()))
    def hashCode(self): return _int32(_java_hash(self.key) ^ _java_hash(self.getValue()))
    __eq__ = equals
    __hash__ = hashCode


class _MapIterator(Object):
    def __init__(self, mapping, entries=False):
        self.mapping, self.entries = mapping, entries
        self.keys, self.index = list(dict.__iter__(mapping)), 0
        self.expected, self.last = mapping._version, _MISSING_KEY

    def _check(self):
        if self.expected != self.mapping._version:
            raise RuntimeError("HashMap iterator: map structurally modified")

    def hasNext(self):
        self._check()
        return self.index < len(self.keys)

    def next(self):
        if not self.hasNext(): raise StopIteration
        self.last = self.keys[self.index]
        self.index += 1
        key = _public_key(self.last)
        return Entry(self.mapping, key) if self.entries else key

    def remove(self):
        self._check()
        if self.last is _MISSING_KEY: raise RuntimeError("HashMap iterator.remove requires one preceding next")
        del self.mapping[_public_key(self.last)]
        self.expected, self.last = self.mapping._version, _MISSING_KEY

    def __iter__(self): return self
    __next__ = next


class _MapView(Object):
    entries = False
    name = "keySet"
    def __init__(self, mapping): self.mapping = mapping
    def __len__(self): return len(self.mapping)
    def __iter__(self): return self.iterator()
    def size(self): return len(self)
    def isEmpty(self): return not self
    def iterator(self): return _MapIterator(self.mapping, self.entries)
    def toArray(self): return list(self)
    def clear(self): self.mapping.clear()
    def contains(self, value): return value in self
    def containsAll(self, values): return all(value in self for value in values)
    def add(self, value): raise TypeError(f"HashMap.{self.name}.add is unsupported")
    def addAll(self, values): raise TypeError(f"HashMap.{self.name}.addAll is unsupported")
    def get(self, index):
        # Retain the port's read-only indexing convenience; mutations are Java
        # set operations, never ArrayList's integer-index remove overload.
        if not 0 <= index < len(self): raise IndexError(index)
        return self.toArray()[index]
    def removeAll(self, values):
        changed = False
        for value in list(values): changed = self.remove(value) or changed
        return changed
    def retainAll(self, values):
        values, changed = list(values), False
        for value in list(self):
            if not any(_java_equals(value, other) for other in values):
                changed = self.remove(value) or changed
        return changed
    def hashCode(self): return _int32(sum(_java_hash(value) for value in self))


class _KeySet(_MapView):
    def __contains__(self, value): return value in self.mapping
    def remove(self, value):
        if value not in self.mapping: return False
        del self.mapping[value]
        return True


class _EntrySet(_MapView):
    entries = True
    name = "entrySet"
    def __contains__(self, value):
        return (isinstance(value, Entry) and value.key in self.mapping
                and _java_equals(self.mapping[value.key], value.getValue()))
    def remove(self, value):
        if value not in self: return False
        del self.mapping[value.key]
        return True


class _MapItems(ItemsView):
    def __contains__(self, item):
        key, value = item
        return key in self._mapping and _java_equals(self._mapping[key], value)


class _MapValues(ValuesView):
    def __contains__(self, value): return any(_java_equals(value, item) for item in self)


class HashMap(dict, Object):
    def __init__(self, values=(), **kwargs):
        self._version = 0
        dict.__init__(self)
        self.update(() if type(values) is int else values, **kwargs)
    def __getitem__(self, key): return dict.__getitem__(self, _map_key(key))
    def __contains__(self, key): return dict.__contains__(self, _map_key(key))
    def __setitem__(self, key, value):
        key = _map_key(key)
        added = not dict.__contains__(self, key)
        dict.__setitem__(self, key, value)
        if added: self._version += 1
    def __delitem__(self, key):
        dict.__delitem__(self, _map_key(key))
        self._version += 1
    def __iter__(self): return _MapIterator(self)
    def __reversed__(self): return (_public_key(key) for key in dict.__reversed__(self))
    def get(self, key, default=None):
        try: return self[key]
        except KeyError: return default
    def put(self, key, value):
        old = self.get(key)
        self[key] = value
        return old
    def update(self, values=(), **kwargs):
        items = ((key, values[key]) for key in values.keys()) if hasattr(values, "keys") else values
        for key, value in items: self[key] = value
        for key, value in kwargs.items(): self[key] = value
    def setdefault(self, key, default=None):
        if key not in self: self[key] = default
        return self[key]
    def pop(self, key, default=_MISSING_KEY):
        if key not in self:
            if default is _MISSING_KEY: raise KeyError(key)
            return default
        value = self[key]
        del self[key]
        return value
    def popitem(self):
        key, value = dict.popitem(self)
        self._version += 1
        return _public_key(key), value
    def clear(self):
        if self:
            dict.clear(self)
            self._version += 1
    def copy(self): return type(self)(self)
    @classmethod
    def fromkeys(cls, keys, value=None): return cls((key, value) for key in keys)
    def __ior__(self, other): self.update(other); return self
    def __or__(self, other): result = self.copy(); result.update(other); return result
    def __ror__(self, other): result = type(self)(other); result.update(self); return result
    def putAll(self, values): self.update(values)
    def remove(self, key): return self.pop(key, None)
    def containsKey(self, key): return key in self
    def containsValue(self, value): return value in self.values()
    def keySet(self): return _KeySet(self)
    def entrySet(self): return _EntrySet(self)
    def keys(self): return KeysView(self)
    def items(self): return _MapItems(self)
    def values(self): return _MapValues(self)
    def size(self): return len(self)
    def isEmpty(self): return not self
    def equals(self, other):
        if not isinstance(other, Mapping): return False
        other = other if isinstance(other, HashMap) else HashMap(other)
        return len(self) == len(other) and all(key in other and _java_equals(value, other[key]) for key, value in self.items())
    def hashCode(self): return _int32(sum(entry.hashCode() for entry in self.entrySet()))
    __eq__ = equals
    def __ne__(self, other): return not self == other
    __hash__ = None


class HashSet(MutableSet, Object):
    def __init__(self, values=()): self._mapping = HashMap.fromkeys(values)
    def __contains__(self, value): return value in self._mapping
    def __iter__(self): return iter(self._mapping)
    def __len__(self): return len(self._mapping)
    def add(self, value):
        changed = value not in self
        self._mapping[value] = None
        return changed
    def discard(self, value): self._mapping.remove(value)
    def clear(self): self._mapping.clear()
    def contains(self, value): return value in self
    def size(self): return len(self)
    def isEmpty(self): return not self
    def iterator(self): return self._mapping.keySet().iterator()
    def toArray(self): return list(self)
    def remove(self, value): return self._mapping.keySet().remove(value)
    def update(self, *values):
        for sequence in values:
            for value in sequence: self.add(value)
    def copy(self): return type(self)(self)
    def union(self, *others): result = self.copy(); result.update(*others); return result
    def difference_update(self, *others):
        for other in others: self._mapping.keySet().removeAll(other)
    def intersection_update(self, *others):
        for other in others: self._mapping.keySet().retainAll(other)
    def symmetric_difference_update(self, other): self ^= other
    def difference(self, *others): result = self.copy(); result.difference_update(*others); return result
    def intersection(self, *others): result = self.copy(); result.intersection_update(*others); return result
    def symmetric_difference(self, other): return self ^ other
    def issubset(self, other): return self <= type(self)(other)
    def issuperset(self, other): return self >= type(self)(other)
    def hashCode(self): return self._mapping.keySet().hashCode()


class String(str, Object):
    def length(self): return len(self.encode("utf-16-le", errors="surrogatepass")) // 2
    def substring(self, start, end=None):
        end = self.length() if end is None else end
        if not 0 <= start <= end <= self.length(): raise IndexError((start, end))
        return String(self.encode("utf-16-le", errors="surrogatepass")[start * 2:end * 2].decode("utf-16-le", errors="surrogatepass"))
    def charAt(self, index): return self.substring(index, index + 1)
    def getBytes(self, encoding="utf-8"): return self.encode(str(encoding))
    def toLowerCase(self): return String(self.lower())
    def toUpperCase(self): return String(self.upper())
    def trim(self): return String(self.strip())
    def contains(self, value): return str(value) in self
    def startsWith(self, value): return self.startswith(str(value))
    def endsWith(self, value): return self.endswith(str(value))
    @staticmethod
    def valueOf(value): return String("null" if value is None else str(value).lower() if isinstance(value, bool) else str(value))
    def hashCode(self):
        data = self.encode("utf-16-le", errors="surrogatepass")
        value = 0
        for index in range(0, len(data), 2):
            value = (31 * value + int.from_bytes(data[index:index + 2], "little")) & 0xFFFFFFFF
        return value - 2 ** 32 if value >= 2 ** 31 else value


class Integer(int, Object):
    MIN_VALUE, MAX_VALUE = -(2 ** 31), 2 ** 31 - 1
    def intValue(self): return (int(self) + 2 ** 31) % 2 ** 32 - 2 ** 31
    def longValue(self): return int(self)
    def equals(self, other): return type(self) is type(other) and int(self) == int(other)
    def hashCode(self): return self.intValue()
    @classmethod
    def parseInt(cls, value, radix=10):
        number = int(str(value), radix)
        if not cls.MIN_VALUE <= number <= cls.MAX_VALUE: raise OverflowError(number)
        return number
    @classmethod
    def valueOf(cls, value): return cls(cls.parseInt(value))


class Long(Integer):
    MIN_VALUE, MAX_VALUE = -(2 ** 63), 2 ** 63 - 1
    parseLong = Integer.__dict__["parseInt"]
    def hashCode(self): return _int32(int(self) ^ (int(self) >> 32))


class Boolean(Object):
    def __init__(self, value): self._value = str(value).lower() == "true" if isinstance(value, str) else bool(value)
    @property
    def value(self): return self._value
    def __bool__(self): return self.value
    def __str__(self): return "true" if self.value else "false"
    def booleanValue(self): return self.value
    def equals(self, other): return type(self) is type(other) and self.value == other.value
    def hashCode(self): return 1231 if self.value else 1237
    __eq__ = equals
    __hash__ = hashCode
    @staticmethod
    def parseBoolean(value): return str(value).lower() == "true"


class Runnable(Object):
    def __init__(self, fn=None): self.fn = fn
    def run(self):
        if self.fn is None: raise NotImplementedError("override Runnable.run")
        return self.fn()


class File(Object):
    def __init__(self, *parts): self.path = os.path.join(*(os.fspath(p) for p in parts))
    def __fspath__(self): return self.path
    def getAbsolutePath(self): return os.path.abspath(self.path)
    def getPath(self): return self.path
    def getName(self): return os.path.basename(self.path)
    def getParent(self): return os.path.dirname(self.path)
    def getParentFile(self): return File(self.getParent())
    def exists(self): return os.path.exists(self.path)
    def isFile(self): return os.path.isfile(self.path)
    def isDirectory(self): return os.path.isdir(self.path)
    def length(self): return os.path.getsize(self.path) if os.path.exists(self.path) else 0
    def mkdirs(self):
        if os.path.isdir(self.path): return False
        os.makedirs(self.path, exist_ok=True)
        return True
    def mkdir(self):
        if os.path.exists(self.path): return False
        os.mkdir(self.path)
        return True
    def delete(self):
        if not os.path.exists(self.path): return False
        os.rmdir(self.path) if os.path.isdir(self.path) else os.remove(self.path)
        return True
    def renameTo(self, destination):
        if not os.path.exists(self.path): return False
        os.rename(self.path, os.fspath(destination))
        return True
    def lastModified(self): return int(os.path.getmtime(self.path) * 1000) if os.path.exists(self.path) else 0
    def listFiles(self): return ArrayList(File(self.path, name) for name in os.listdir(self.path))


class Uri(Object):
    def __init__(self, text): self.text, self.parts = str(text), urlsplit(str(text))
    @classmethod
    def parse(cls, text): return cls(text)
    def toString(self): return self.text
    def __str__(self): return self.text
    @classmethod
    def fromFile(cls, file):
        from pathlib import Path
        return cls(Path(os.fspath(file)).absolute().as_uri())
    def getScheme(self): return self.parts.scheme
    def getHost(self): return self.parts.hostname
    def getPath(self): return self.parts.path
    def getQueryParameter(self, name): return next(iter(parse_qs(self.parts.query).get(name, ())), None)


class System:
    @staticmethod
    def currentTimeMillis(): return time.time_ns() // 1_000_000
    @staticmethod
    def nanoTime(): return time.monotonic_ns()


class UUID(Object):
    def __init__(self, value): self.value = uuid.UUID(str(value))
    @classmethod
    def randomUUID(cls): return cls(uuid.uuid4())
    @classmethod
    def fromString(cls, value): return cls(value)
    def __str__(self): return str(self.value)


class Arrays:
    @staticmethod
    def asList(*values): return ArrayList(values[0] if len(values) == 1 and isinstance(values[0], (list, tuple)) else values)
    @staticmethod
    def copyOf(values, length): return list(values[:length]) + [None] * max(0, length - len(values))
    @staticmethod
    def equals(left, right): return list(left) == list(right)


class Collections:
    @staticmethod
    def emptyList(): return ()
    @staticmethod
    def singletonList(value): return (value,)
    @staticmethod
    def sort(values): values.sort()
    @staticmethod
    def reverse(values): values.reverse()
    @staticmethod
    def unmodifiableList(values): return ListView(values, readonly=True)
    @staticmethod
    def unmodifiableMap(values):
        from types import MappingProxyType
        return MappingProxyType(values)


def install():
    from virtualjava import register_class
    classes = {"java.lang.Object": Object, "java.lang.Class": ClassInfo, "java.lang.String": String,
               "java.lang.Integer": Integer, "java.lang.Long": Long, "java.lang.Boolean": Boolean,
               "java.lang.Runnable": Runnable, "java.lang.System": System,
               "java.util.ArrayList": ArrayList, "java.util.LinkedList": ArrayList,
               "java.util.HashMap": HashMap, "java.util.LinkedHashMap": HashMap,
               "java.util.HashSet": HashSet, "java.io.File": File, "android.net.Uri": Uri}
    classes.update({"java.util.UUID": UUID, "java.util.Arrays": Arrays, "java.util.Collections": Collections})
    for name, cls in classes.items():
        if "_fqcn" not in cls.__dict__: cls._fqcn = name
        register_class(name, cls)
    interfaces = {
        "android.view.View$OnClickListener": "onClick",
        "android.view.View$OnLongClickListener": "onLongClick",
        "android.view.View$OnTouchListener": "onTouch",
        "android.view.View$OnKeyListener": "onKey",
        "android.widget.SeekBar$OnSeekBarChangeListener": "onProgressChanged",
        "android.content.DialogInterface$OnClickListener": "onClick",
        "android.content.DialogInterface$OnDismissListener": "onDismiss",
        "android.content.DialogInterface$OnCancelListener": "onCancel",
        "org.telegram.ui.ActionBar.AlertDialog$OnButtonClickListener": "onClick",
    }
    def abstract(self, *args): raise NotImplementedError("interface callback is not implemented")
    for name, method in interfaces.items():
        register_class(name, type(name.rsplit("$", 1)[-1], (Object,), {method: abstract, "_fqcn": name}))
    from extera_utils import classes as sdk_classes
    previous_getattr = sdk_classes.JavaHelper.__getattr__
    def helper_getattr(self, name):
        value = previous_getattr(self, name)
        if callable(value) and object.__getattribute__(self, "_j_ignore_result"):
            def ignored(*args, **kwargs):
                value(*args, **kwargs)
                return None
            return ignored
        return value
    sdk_classes.JavaHelper.__getattr__ = helper_getattr
    return classes
