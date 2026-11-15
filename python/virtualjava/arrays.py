"""Interpreter-local Java descriptors; fixed-length, C-marshallable array storage."""


def _integer(name, bits):
    def convert(value, *, truncate=False):
        value = int(value)
        if truncate:
            return (value + (1 << (bits - 1))) % (1 << bits) - (1 << (bits - 1))
        if not -(1 << (bits - 1)) <= value < (1 << (bits - 1)):
            raise OverflowError(f"{name} out of range")
        return value
    return convert


def _char(value):
    value = chr(value) if isinstance(value, int) else str(value)
    if len(value.encode("utf-16-le", errors="surrogatepass")) != 2:
        raise ValueError("jchar requires one UTF-16 code unit")
    return value


def _primitive(name, descriptor, convert, default):
    # Distinct singleton converters even where Python scalar storage is shared.
    def primitive(*args, **kwargs): return convert(*args, **kwargs)
    primitive.__name__ = "j" + name
    primitive._java_descriptor, primitive._java_default = descriptor, default
    return primitive


PRIMITIVES = {
    name: _primitive(name, descriptor, convert, default)
    for name, descriptor, convert, default in (
        ("byte", "B", _integer("jbyte", 8), 0),
        ("short", "S", _integer("jshort", 16), 0),
        ("int", "I", _integer("jint", 32), 0),
        ("long", "J", _integer("jlong", 64), 0),
        ("float", "F", float, 0.0), ("double", "D", float, 0.0),
        ("boolean", "Z", bool, False), ("char", "C", _char, "\0"),
        ("void", "V", lambda: None, None),
    )
}
PRIMITIVE_DESCRIPTORS = {value._java_descriptor: value for value in PRIMITIVES.values()}
_ARRAY_TYPES = {}
_FINAL_VALUES = frozenset("Ljava/lang/" + name + ";" for name in ("String", "Integer", "Long", "Boolean"))


def component_descriptor(element):
    # These are explicit compatibility aliases, not inference from a converter's
    # return type (jint/jlong and jfloat/jdouble have different Java identities).
    for alias, name in ((int, "int"), (float, "double"), (bool, "boolean")):
        if element is alias: return PRIMITIVES[name]._java_descriptor
    if element is str: return "Ljava/lang/String;"
    if element is object: return "Ljava/lang/Object;"
    metadata = vars(element) if isinstance(element, type) or callable(element) else {}
    descriptor = metadata.get("_java_descriptor")
    if isinstance(descriptor, str): return descriptor
    from .proxy import JavaClass
    name = element.__name__ if isinstance(element, JavaClass) else metadata.get("_fqcn")
    if isinstance(name, str) and name:
        return "L" + name.replace(".", "/") + ";"
    raise TypeError("jarray component requires an explicit Java class or primitive descriptor")


def _assignable(target, source):
    wanted, actual = target.component_descriptor, source.component_descriptor
    if wanted == actual: return True
    if wanted in PRIMITIVE_DESCRIPTORS or actual in PRIMITIVE_DESCRIPTORS: return False
    if wanted == "Ljava/lang/Object;": return True
    if wanted in _FINAL_VALUES or actual in _FINAL_VALUES: return False
    if source.component_type is target.component_type: return False
    # Only declared reference inheritance is useful here. In particular Long's
    # Python implementation reuses Integer; it is not Java Integer inheritance.
    return issubclass(source.component_type, target.component_type)


class _ArrayClass(type):
    def __subclasscheck__(cls, other):
        if type.__subclasscheck__(cls, other): return True
        return (isinstance(other, _ArrayClass) and cls.component_descriptor is not None
                and other.component_descriptor is not None and _assignable(cls, other))

    def __instancecheck__(cls, value): return issubclass(type(value), cls)


class JavaArray(list, metaclass=_ArrayClass):
    component_descriptor = None

    @property
    def length(self): return len(self)

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            value = [self._convert(item) for item in value]
            if len(value) != len(range(*index.indices(len(self)))): raise TypeError("Java array length is fixed")
        else:
            value = self._convert(value)
        list.__setitem__(self, index, value)

    def _resize(self, *args, **kwargs): raise TypeError("Java array length is fixed")
    append = extend = insert = pop = remove = clear = __delitem__ = __iadd__ = __imul__ = _resize


def array_type(element, descriptor=None):
    descriptor = component_descriptor(element) if descriptor is None else descriptor
    if descriptor == "V": raise TypeError("jarray cannot have void components")
    primitive = PRIMITIVE_DESCRIPTORS.get(descriptor)
    if primitive is not None: element = primitive
    found = _ARRAY_TYPES.get(descriptor)
    if found is not None: return found
    default = primitive._java_default if primitive is not None else None

    def convert(value):
        if primitive is not None:
            if value is None: raise TypeError("primitive array element cannot be null")
            return primitive(value)
        if value is None or descriptor == "Ljava/lang/Object;": return value
        if descriptor == "Ljava/lang/String;" and isinstance(value, str): return value
        if descriptor in _FINAL_VALUES:
            accepted = type(value) is element
        else:
            accepted = isinstance(value, element)
        if accepted: return value
        raise TypeError(f"array element must be {descriptor} or null")

    def initialize(self, values=()):
        if type(values) is int:
            if not 0 <= values <= 1_000_000: raise ValueError("array size must be 0...1000000")
            values = [default] * values
        converted = []
        for value in values:
            if len(converted) >= 1_000_000: raise ValueError("array exceeds 1000000 elements")
            converted.append(convert(value))
        list.__init__(self, converted)

    cls = _ArrayClass("JavaArray[" + descriptor + "]", (JavaArray,), {
        "component_type": element, "component_descriptor": descriptor,
        "_java_descriptor": "[" + descriptor, "_convert": staticmethod(convert),
        "__module__": __name__, "__init__": initialize,
    })
    return _ARRAY_TYPES.setdefault(descriptor, cls)


def byte_array_bytes(value):
    if isinstance(value, JavaArray) and type(value).component_descriptor == "B":
        return bytes(item & 0xff for item in value)
    return None


def reset_array_cache():
    """Explicit backend-reset seam for tests; primitive identities are independent."""
    _ARRAY_TYPES.clear()
