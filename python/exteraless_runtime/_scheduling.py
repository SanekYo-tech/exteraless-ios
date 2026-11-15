"""Named SDK queues mapped to generation-bound native owner-queue tasks."""

import threading

from ._callbacks import admitted_id
from ._java_types import Object, Runnable
from ._platform import RuntimeStateError


class OwnerQueue(Object):
    def __init__(self, scheduler, name): self.scheduler, self.name = scheduler, str(name)
    def postRunnable(self, callback, delay=0): return self.scheduler.post(callback, self.name, delay)
    def cancelRunnable(self, callback): return self.scheduler.cancel(callback)
    def getName(self): return self.name


class Scheduler:
    def __init__(self, platform):
        self.platform = platform
        self.tasks = {}

    def post(self, callback, queue, delay=0):
        delay = int(delay or 0)
        if not 0 <= delay <= 86_400_000: raise ValueError("native delay must be 0...86400000 milliseconds")
        if not callable(callback) and not callable(getattr(callback, "run", None)):
            raise TypeError("queue work must be a callable or Runnable")
        p = self.platform
        account = p.loader.client_utils.get_hook_account()
        lease = p.callbacks.new("queue:" + str(queue), lambda ident: p.call("cancelOwnerTask", ident))
        def forget():
            with p.callbacks.lock:
                current = self.tasks.get(lease.id)
                if current is not None and current[0] is lease:
                    self.tasks.pop(lease.id)
        def run():
            forget()
            callback() if callable(callback) else callback.run()
            # java.lang.Runnable.run is void, including non-JSON Python results.
            return None
        try:
            with p.callbacks.lock:
                wrapper = lease.wrap(run, account=account, terminal=True)
                # A zero-delay callback/release can precede xt_call_host's return
                # on a background poster. Native owns its handle during admission;
                # only failed admission rolls that ownership back to Python.
                lease.native_owned = True
                lease.on_close = forget
            # This is a narrow transport exception, not execution on this thread.
            # Native captures the originating CallbackOwner and enqueues only.
            request = {"op": "call", "fqcn": "exteraless.ios.Runtime", "member": "postToOwner",
                       "args": [wrapper, delay, str(queue)], "kwargs": {}, "instance": None, "value": None}
            ident = admitted_id(p.bridge.xt_call_host(request))
            with p.callbacks.lock:
                lease.id = ident
                if lease.open:
                    self.tasks[ident] = (lease, callback)
        except BaseException:
            with p.callbacks.lock:
                lease.native_owned = False
                lease.close()
            raise
        return ident

    def cancel(self, callback_or_id):
        self.platform.check_worker()
        with self.platform.callbacks.lock:
            selected = [(ident, lease) for ident, (lease, callback) in self.tasks.items()
                         if ident == callback_or_id or callback is callback_or_id]
        cancelled = False
        for ident, lease in selected:
            with self.platform.callbacks.lock:
                current = self.tasks.get(ident)
                if current is None or current[0] is not lease or not lease.open: continue
            result = self.platform.call("cancelOwnerTask", ident)
            if type(result) is not bool: raise RuntimeStateError("cancelOwnerTask must return Bool")
            if result:
                lease.close()  # on_close removes only this exact captured lease.
                cancelled = True
        return cancelled


def install(platform, android, client, services):
    from virtualjava import register_class
    scheduler = Scheduler(platform)
    platform.scheduler = scheduler
    queues = {}

    def queue(name):
        name = str(name)
        if name not in queues: queues[name] = OwnerQueue(scheduler, name)
        return queues[name]
    client.get_queue_by_name = queue
    client.run_on_queue = lambda fn, queue=client.PLUGINS_QUEUE, delay=0, delay_ms=None: (
        scheduler.post(fn, queue, delay if delay_ms is None else delay_ms), queues.setdefault(str(queue), OwnerQueue(scheduler, queue)))[1]
    services.postRunnable = lambda dispatch_queue, callback, delay: scheduler.post(callback, dispatch_queue.name, delay)
    services.runnable = lambda callback: Runnable(callback)

    previous_ui = android.run_on_ui_thread
    def run_on_ui_thread(fn, delay=0):
        if threading.get_ident() == platform.thread_id:
            return previous_ui(fn, delay)
        return scheduler.post(fn, "UI", delay)
    android.run_on_ui_thread = run_on_ui_thread
    client.run_on_ui_thread = run_on_ui_thread
    class DispatchQueue(OwnerQueue):
        def __init__(self, name): super().__init__(scheduler, name)
    register_class("org.telegram.messenger.DispatchQueue", DispatchQueue)
