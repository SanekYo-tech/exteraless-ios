"""Typed native-service facades. An asynchronous snapshot is never a fake User."""

from ._callbacks import admitted_id
from ._codec import Snapshot
from ._java_types import Object
from ._notifications import EVENTS, notification_arguments, supported_events
from ._platform import RuntimeStateError, UnsupportedSurfaceError
from ._tl import peer_model, to_wire


def snapshot(value):
    if isinstance(value, dict): return Snapshot((key, snapshot(item)) for key, item in value.items())
    if isinstance(value, list): return [snapshot(item) for item in value]
    return value


class NativeOperation(Object):
    def __init__(self, platform, lease, cancel):
        self.platform, self.lease, self.cancel_member = platform, lease, cancel

    @property
    def id(self): return self.lease.id

    def cancel(self):
        self.platform.check_worker()
        lease = self.lease
        if not lease.open: return False
        result = self.platform.call(self.cancel_member, lease.id)
        if type(result) is not bool: raise RuntimeStateError("native cancellation must return Bool")
        if result: lease.close()
        return result

    def state(self):
        self.platform.check_worker()
        if not self.lease.open: raise RuntimeStateError("native subscription is closed")
        value = self.platform.call("nativeServiceState", self.id)
        if not isinstance(value, dict) or type(value.get("ready")) is not bool or not isinstance(value.get("kind"), str) or "value" not in value:
            raise RuntimeStateError("nativeServiceState must return {ready,kind,value}")
        return snapshot(value)


def install(platform, client):
    from virtualjava import register_class

    def resolve_account(value):
        if value is not None and type(value) is not int:
            raise TypeError("account must be an integer slot")
        result = client._resolve_account(value)
        if type(result) is not int or not 0 <= result < 2 ** 31: raise ValueError("account must be a nonnegative Int32 slot")
        return result

    def query(member, model, callback, *, subscription=False, cancel="nativeServiceCancel"):
        if callback is None or not callable(callback):
            raise UnsupportedSurfaceError(f"{member} requires an asynchronous (value,error) callback; no synchronous snapshot is invented")
        platform.check_worker()
        if not platform.supported(member):
            raise UnsupportedSurfaceError(f"native provider does not export {member}")
        platform.loader.require_permission("messages.read", member, plugin_id=platform.plugin_id)
        if member == "nativeDownload":
            for permission in ("network", "files"):
                platform.loader.require_permission(permission, member, plugin_id=platform.plugin_id)
        model = dict(model)
        model["account"] = resolve_account(model.get("account"))
        lease = platform.callbacks.new(member, lambda ident: platform.call(cancel, ident))
        def receive(value, error):
            callback(snapshot(value), snapshot(error))
            return None
        try:
            fn = lease.wrap(receive, account=model["account"], terminal=not subscription)
            lease.native_owned = True
            lease.id = admitted_id(platform.call(member, to_wire(model), fn))
        except BaseException:
            lease.native_owned = False
            lease.close()
            raise
        return NativeOperation(platform, lease, cancel)

    platform.native_query = query

    class AccountFacade(Object):
        _native_methods = ()
        def __init__(self, index): self.currentAccount = resolve_account(index)
        @classmethod
        def getInstance(cls, index): return cls(index)
        def getCurrentAccount(self): return self.currentAccount
        def supported(self): return tuple(name for name in self._native_methods if platform.supported(name))

    class Messages(AccountFacade):
        _native_methods = ("nativeGetUser", "nativeGetChat", "nativeObservePeer", "nativePeerInfo")
        def getUser(self, user_id, callback=None): return query("nativeGetUser", {"account": self.currentAccount, "id": user_id}, callback)
        def getChat(self, peer, callback=None):
            model = {"account": self.currentAccount}
            model["peer" if isinstance(peer, dict) else "id"] = peer
            return query("nativeGetChat", model, callback)
        def observePeer(self, peer, callback): return query("nativeObservePeer", {"account": self.currentAccount, "peer": peer_model(peer)}, callback, subscription=True)
        def getPeerInfo(self, peer, callback): return query("nativePeerInfo", {"account": self.currentAccount, "peer": peer_model(peer)}, callback)

    class Contacts(AccountFacade):
        _native_methods = ("nativeGetContacts",)
        def getContacts(self, callback=None, offset=0, limit=100):
            return query("nativeGetContacts", {"account": self.currentAccount, "offset": offset, "limit": limit}, callback)

    class Media(AccountFacade):
        _native_methods = ("nativeMessageMedia",)
        def getMessageMedia(self, peer, message_id, callback):
            return query("nativeMessageMedia", {"account": self.currentAccount, "peer": peer_model(peer), "messageId": message_id}, callback)

    class Files(AccountFacade):
        _native_methods = ("nativeResourceStatus", "nativeObserveResource", "nativeDownload")
        def getResourceStatus(self, peer, message_id, file_id, callback):
            return query("nativeResourceStatus", {"account": self.currentAccount, "peer": peer_model(peer), "messageId": message_id, "fileId": file_id}, callback)
        def observeResource(self, peer, message_id, file_id, callback):
            return query("nativeObserveResource", {"account": self.currentAccount, "peer": peer_model(peer), "messageId": message_id, "fileId": file_id}, callback, subscription=True)
        def loadFile(self, model, callback=None):
            if not isinstance(model, dict): raise UnsupportedSurfaceError("loadFile requires an explicit peer/messageId/fileId model")
            return query("nativeDownload", dict(model, account=self.currentAccount), callback)

    class Notifications(AccountFacade):
        _native_methods = ("nativeNotificationSettings",)
        def getPeerSettings(self, peer, callback):
            return query("nativeNotificationSettings", {"account": self.currentAccount, "peer": peer_model(peer)}, callback)

    class Center(AccountFacade):
        _events = EVENTS
        def __init__(self, index): super().__init__(index); self.observers = {}
        def supported(self):
            return supported_events(platform.call("notificationSupported", self.currentAccount))
        def event_id(self, event):
            if type(event) is int and event in self._events: return event
            for ident, name in self._events.items():
                if event == name: return ident
            raise UnsupportedSurfaceError(f"native notification publisher is unavailable: {event}")
        def addObserver(self, delegate, event):
            event = self.event_id(event)
            if not any(row["id"] == event for row in self.supported()):
                raise UnsupportedSurfaceError(f"native notification publisher is unavailable: {event}")
            platform.loader.require_permission("messages.read", "notificationSubscribe", plugin_id=platform.plugin_id)
            if event in (142, 143): platform.loader.require_permission("files", "notificationSubscribe", plugin_id=platform.plugin_id)
            if not callable(getattr(delegate, "didReceivedNotification", None)):
                raise TypeError("notification delegate requires didReceivedNotification")
            key = (id(delegate), event)
            if key in self.observers: return
            lease = platform.callbacks.new("notification", lambda ident: platform.call("notificationUnsubscribe", ident))
            def received(notification_id, actual_account, args):
                if type(actual_account) is not int or actual_account != self.currentAccount:
                    raise RuntimeStateError("notification changed its pinned account")
                if type(notification_id) is not int or notification_id != event:
                    raise RuntimeStateError("notification changed its event")
                delegate.didReceivedNotification(notification_id, actual_account, notification_arguments(event, actual_account, args))
                return None
            def forget():
                with platform.callbacks.lock:
                    if self.observers.get(key) is lease: self.observers.pop(key)
            try:
                # Original delegate gets the account argument, not an implicit hook scope.
                callback = lease.wrap(received)
                lease.on_close = forget
                lease.native_owned = True
                lease.id = admitted_id(platform.call("notificationSubscribe", {"account": self.currentAccount, "event": event}, callback))
            except BaseException:
                lease.native_owned = False
                lease.close(); raise
            with platform.callbacks.lock:
                if lease.open: self.observers[key] = lease
        def removeObserver(self, delegate, event):
            platform.check_worker()
            event = self.event_id(event)
            lease = self.observers.pop((id(delegate), event), None)
            if lease is not None: lease.dispose()
        def postNotificationName(self, *args):
            raise UnsupportedSurfaceError("plugins cannot synthesize native NotificationCenter events")

    centers = {}
    for event, name in EVENTS.items(): setattr(Center, name, event)
    def center(account=None):
        index = resolve_account(account)
        if index not in centers: centers[index] = Center(index)
        return centers[index]
    Center.getInstance = staticmethod(center)

    class Delegate(Object):
        def didReceivedNotification(self, notification_id, account, args): pass
        @property
        def java(self): return self
        def start_observing(self, notification_id, account=None): center(account).addObserver(self, notification_id); return self
        def stop_observing(self, notification_id, account=None): center(account).removeObserver(self, notification_id); return self

    mappings = {
        "get_messages_controller": ("org.telegram.messenger.MessagesController", Messages),
        "get_contacts_controller": ("org.telegram.messenger.ContactsController", Contacts),
        "get_media_data_controller": ("org.telegram.messenger.MediaDataController", Media),
        "get_file_loader": ("org.telegram.messenger.FileLoader", Files),
        "get_download_controller": ("org.telegram.messenger.DownloadController", Files),
        "get_notifications_controller": ("org.telegram.messenger.NotificationsController", Notifications),
    }
    for method, (fqcn, cls) in mappings.items():
        register_class(fqcn, cls)
        def accessor(kind):
            def get(account=None): return kind(resolve_account(account))
            return get
        setattr(client, method, accessor(cls))
    client.get_notifications_settings = lambda account=None: Notifications(resolve_account(account))
    client.get_notification_center = center
    client.NotificationCenterDelegate = Delegate
    register_class("org.telegram.messenger.NotificationCenter", Center)
    register_class("org.telegram.messenger.NotificationCenter$NotificationCenterDelegate", Delegate)
    # AccountClient already delegates to these module-level functions.
    platform.controller_caches = centers
