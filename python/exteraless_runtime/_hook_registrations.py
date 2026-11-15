"""Direct Java hook calls share the original BasePlugin registration ledger.

BasePlugin performs its bookkeeping before delegating here. Mutate that same
list in place: dispatch and priority queries must never consult a second cache.
"""

from ._platform import RuntimeStateError


def _instance(platform, *, removing=False):
    # Validate against C's immutable interpreter id as well as the facade's
    # check_plugin. No Python owner token becomes authority for a native call.
    platform.bridge.xt_set_plugin_id(platform.plugin_id)
    record = platform.loader.plugins.get(platform.plugin_id)
    if not platform.callbacks.active:
        raise RuntimeStateError("hook registration belongs to an inactive plugin")
    if record is None:
        # The SDK pops its record before on_plugin_unload. Removal during that
        # callback is already effective; _cleanup still owns the retired ledger.
        if removing: return None
        raise RuntimeStateError("hook registration belongs to an inactive plugin")
    instance = record.instance
    if instance.plugin_id != platform.plugin_id:
        raise RuntimeStateError("hook registration belongs to another plugin")
    return instance


def _priority(value):
    value = int(value)
    if not -(2 ** 31) <= value < 2 ** 31:
        raise ValueError("hook priority must fit Int32")
    return value


def add_request(platform, name, match_substring, priority):
    instance = _instance(platform)
    if name is None or name == "": return None
    if not isinstance(name, str): raise TypeError("hook name must be a string")
    priority = _priority(priority)
    modes = {bool(match_substring)}
    hooks = instance._exteraless_state("_exteraless_request_hooks", list)
    retained = []
    for pattern, substring, previous in hooks:
        if pattern == name:
            # PluginsController.priorityKey omits the exact/substring mode.
            # Both routes therefore share the highest registration for this key.
            modes.add(substring)
            priority = max(priority, previous)
        else:
            retained.append((pattern, substring, previous))
    hooks[:] = retained + [(name, mode, priority) for mode in (False, True) if mode in modes]


def remove_request(platform, name):
    instance = _instance(platform, removing=True)
    if instance is None: return None
    if name is None: return None
    if not isinstance(name, str): raise TypeError("hook name must be a string")
    hooks = instance._exteraless_state("_exteraless_request_hooks", list)
    # Removing a key removes every priority and both matching modes, exactly as
    # unregisterRequestHook; a later add starts a fresh priority for that key.
    hooks[:] = [entry for entry in hooks if entry[0] != name]


def add_send(platform, priority):
    instance = _instance(platform)
    priority = _priority(priority)
    # The send registry uses put, rather than the request registry's max merge.
    instance.__dict__["_exteraless_send_message_priority"] = priority
    instance.__dict__["_exteraless_send_message_registered"] = True


def remove_send(platform):
    instance = _instance(platform, removing=True)
    if instance is None: return None
    instance.__dict__["_exteraless_send_message_registered"] = False
    instance.__dict__.pop("_exteraless_send_message_priority", None)


def send_priority(instance):
    if not instance.__dict__.get("_exteraless_send_message_registered", False):
        return None
    value = instance.__dict__.get("_exteraless_send_message_priority", 0)
    if type(value) is not int or not -(2 ** 31) <= value < 2 ** 31:
        raise ValueError("registered send hook priority must be an Int32")
    return value
