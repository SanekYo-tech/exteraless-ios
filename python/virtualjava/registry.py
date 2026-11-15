"""Explicit interpreter-local Python ports. Unknown classes still use C."""

_classes = {}
_factories = {}
_native_metadata = {}


def register_native_metadata(fqcn, resolver):
    """Side-effect-free live metadata from an installed native dispatcher."""
    if not isinstance(fqcn, str) or not callable(resolver):
        raise TypeError("native metadata requires a class name and resolver")
    _native_metadata[fqcn] = resolver


def native_member_kind(fqcn, member):
    resolver = _native_metadata.get(fqcn)
    if resolver is None:
        return None
    kind = resolver(member)
    if kind not in ("field", "method", "unknown"):
        raise TypeError("native member_kind returned an invalid descriptor")
    return kind


def register_class(fqcn, implementation, *, replace=False):
    if not isinstance(fqcn, str) or not fqcn or not isinstance(implementation, type):
        raise TypeError("register_class requires a qualified name and a real Python class")
    if not replace and (fqcn in _classes or fqcn in _factories):
        if _classes.get(fqcn) is implementation:
            return
        raise ValueError(f"class already registered: {fqcn}")
    _factories.pop(fqcn, None)
    _classes[fqcn] = implementation


def register_factory(fqcn, factory):
    """Lazily materialize a class for an exact schema alias, never a name guess."""
    if not isinstance(fqcn, str) or not callable(factory):
        raise TypeError("invalid class factory")
    if fqcn in _classes or fqcn in _factories:
        raise ValueError(f"class already registered: {fqcn}")
    _factories[fqcn] = factory


def get_registered(fqcn):
    found = _classes.get(fqcn)
    if found is None and fqcn in _factories:
        found = _factories[fqcn]()
        if not isinstance(found, type):
            raise TypeError(f"registered factory did not return a class: {fqcn}")
        _classes[fqcn] = found
    return found


def registered_classes():
    return frozenset(_classes) | frozenset(_factories)


def unregister_class(fqcn):
    _classes.pop(fqcn, None)
    _factories.pop(fqcn, None)


def clear_registry():
    _classes.clear()
    _factories.clear()
    _native_metadata.clear()
