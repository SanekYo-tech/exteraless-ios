"""Generation-scoped, bounded callback leases on the plugin's owner worker."""

import threading
import traceback

from ._platform import RuntimeStateError


class Lease:
    def __init__(self, manager, kind, cancel=None):
        self.manager, self.kind, self.cancel = manager, kind, cancel
        self.generation = manager.generation
        self.id = None
        self.handles = []
        self.open = True
        self.native_owned = False
        self.on_close = None

    def wrap(self, callback, *, account=None, terminal=False):
        manager = self.manager
        if callback is not None and not callable(callback):
            raise TypeError("callback must be callable")

        def invoke(*args):
            manager.platform.check_worker()
            with manager.lock:
                if not self.open or not manager.active or self.generation != manager.generation:
                    raise RuntimeStateError("callback belongs to a closed plugin generation")
            try:
                loader = manager.platform.loader
                with loader.plugin_context(manager.platform.plugin_id), loader.client_utils.hook_scope(account):
                    return callback(*args) if callback is not None else None
            except BaseException:
                manager.report_error(self.kind)
                raise
            finally:
                if terminal:
                    self.close()

        with manager.lock:
            if not self.open or not manager.active or len(manager.handles) >= manager.max_handles:
                raise RuntimeStateError("callback lease is closed or its handle budget is exhausted")
            handle = manager.platform.bridge.xt_register_handle(invoke)
            if type(handle) is not int or handle <= 0:
                raise RuntimeStateError("bridge returned an invalid Python callback handle")
            self.handles.append(handle)
            manager.handles.add(handle)
        return invoke

    def close(self):
        manager = self.manager
        with manager.lock:
            if not self.open:
                return
            self.open = False
            for handle in self.handles:
                if not self.native_owned:
                    manager.platform.bridge.xt_release_handle(handle)
                manager.handles.discard(handle)
            self.handles.clear()
            manager.leases.discard(self)
            if self.on_close is not None:
                notify, self.on_close = self.on_close, None
                notify()

    def dispose(self):
        try:
            if self.open and self.id is not None and self.cancel is not None:
                self.cancel(self.id)
        finally:
            self.close()


class CallbackLeases:
    max_handles = 1024
    max_leases = 128

    def __init__(self, platform):
        self.platform = platform
        self.generation = 0
        self.active = False
        self.leases = set()
        self.handles = set()
        self.lock = threading.RLock()

    def begin(self):
        self.platform.check_worker()
        with self.lock:
            if self.leases:
                raise RuntimeStateError("previous generation still has callback leases")
            self.generation += 1
            self.active = True

    def release_handles(self, handles):
        self.platform.check_worker()
        released = set(handles)
        with self.lock:
            for lease in list(self.leases):
                if not released.intersection(lease.handles):
                    continue
                lease.handles[:] = [handle for handle in lease.handles if handle not in released]
                if not lease.handles:
                    lease.close()
            for handle in released:
                self.handles.discard(handle)
                self.platform.bridge.xt_release_handle(handle)

    def new(self, kind, cancel=None):
        with self.lock:
            if self.platform.owner_token is None:
                raise RuntimeStateError("native host must bind_owner_json before wave-2 callback operations")
            if not self.active or len(self.leases) >= self.max_leases:
                raise RuntimeStateError("plugin callback generation is inactive or full")
            lease = Lease(self, kind, cancel)
            self.leases.add(lease)
            return lease

    def report_error(self, phase):
        # Preserve the original callback exception if logging itself is unavailable.
        text = traceback.format_exc()
        try:
            self.platform.call("logEvent", {"level": "E", "phase": phase,
                                            "message": text.splitlines()[-1], "traceback": text})
        except Exception:
            try:
                self.platform.log(self.platform.plugin_id, f"callback {phase} failed:\n{text}")
            except Exception:
                pass

    def end(self):
        self.platform.check_worker()
        with self.lock:
            self.active = False
            leases = list(self.leases)
        errors = []
        for lease in leases:
            try:
                lease.dispose()
            except Exception as error:
                errors.append(error)
        if errors:
            raise errors[0]


def admitted_id(result, key="id"):
    if not isinstance(result, dict) or not isinstance(result.get(key), str) or not result[key]:
        raise RuntimeStateError(f"native operation did not return {{{key}: nonempty String}}")
    return result[key]
