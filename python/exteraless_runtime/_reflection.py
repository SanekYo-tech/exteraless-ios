"""Fail-soft SDK class lookup against real ports and backend class metadata."""


def install(platform):
    import hook_utils
    from extera_utils.class_aliases import unwrap
    from virtualjava import finder, get_registered
    from virtualjava.proxy import JavaClass

    current = hook_utils.find_class
    if getattr(current, "_exteraless_reflection_platform", None) is platform:
        return
    original = getattr(current, "_exteraless_reflection_original", current)

    def find_class(name: str):
        try:
            platform.check_worker()
            # Keep the original alias/substitute adaptation and permission gates.
            found = original(name)
            if found is None:
                return None
            target = unwrap(found)
            if not isinstance(target, JavaClass):
                return found  # Local ports, schema classes and Python array types.
            fqcn = target.__name__
            if get_registered(fqcn) is not None:
                return found
            # The original helper tolerates a failed guard. At the native lookup
            # boundary a failed owner/permission query must never imply existence.
            if not platform.loader.guard_java_class(fqcn):
                return None
            if finder._State.backend.class_exists(fqcn) is not True:
                return None
            return found
        except Exception:
            return None  # Includes absent, denied, malformed or unavailable metadata.

    find_class._exteraless_reflection_platform = platform
    find_class._exteraless_reflection_original = original
    hook_utils.find_class = find_class
