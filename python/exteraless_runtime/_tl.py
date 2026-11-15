"""Schema-backed TL Python data and the native asynchronous request boundary."""

import base64
import json
import math
import os
from collections.abc import MutableSequence
from pathlib import Path
from types import MappingProxyType

from ._callbacks import admitted_id
from ._java_types import Object, ArrayList
from ._platform import RuntimeStateError, UnsupportedSurfaceError


_OMITTED = object()


class TLObject(Object):
    _definition = None
    _field_aliases = {}

    def __init__(self, /, **fields):
        # Native TL constructors (including user) have a Boolean field named
        # "self". Keep the receiver positional-only so that wire key stays data.
        object.__setattr__(self, "_values", {})
        object.__setattr__(self, "_tl_context", None)
        for name, value in fields.items():
            setattr(self, name, value)

    def __getattr__(self, name):
        key = self._field_aliases.get(name, name)
        try:
            return self._values[key]
        except KeyError:
            raise AttributeError(f"{type(self).__name__} has no populated field {name!r}") from None

    def __setattr__(self, name, value):
        if name in ("_exteraless_tl_context", "_tl_context"):
            raise AttributeError("native TL context is read-only")
        if name.startswith("_exteraless_"):
            object.__setattr__(self, name, value)
            return
        name = self._field_aliases.get(name, name)
        if self._definition is None or name not in {field["name"] for field in self._definition["params"]}:
            raise AttributeError(f"unknown TL field {name!r} on {type(self).__name__}")
        field = next(field for field in self._definition["params"] if field["name"] == name)
        if field["type"].endswith("?true") and type(value) is not bool:
            raise TypeError(f"{self._definition['name']}.{name}: Boolean flag requires Bool")
        self._values[name] = value
        if field["type"].endswith("?true"):
            _boolean_masks(self._values, (field,), self._definition["name"])

    @property
    def _exteraless_tl_context(self): return self._tl_context

    def to_dict(self):
        return to_wire(self)


def _boolean_masks(values, fields, name):
    """Java serializers rewrite flag-true bits, never value-optional presence.

    Preserve every other bit, including unknown bits which the native validator
    must still reject. An omitted mask remains native-inferred; shared-bit value
    companions are neither supplied nor removed by this Boolean-only operation.
    """
    for field in fields:
        if not field["type"].endswith("?true") or field["name"] not in values: continue
        value = values[field["name"]]
        if type(value) is not bool: raise TypeError(f"{name}.{field['name']}: Boolean flag requires Bool")
        word, bit = field["type"].split("?", 1)[0].split(".")
        mask = values.get(word)
        if mask is None: continue
        if type(mask) is not int or not -(2 ** 31) <= mask < 2 ** 32:
            raise ValueError(f"{name}.{word}: expected a 32-bit flags word")
        bits = mask & 0xffffffff
        bits = bits | (1 << int(bit)) if value else bits & ~(1 << int(bit))
        values[word] = bits - 2 ** 32 if mask < 0 and bits >= 2 ** 31 else bits


def to_wire(value, depth=0):
    if depth > 64:
        raise ValueError("TL data nesting exceeds 64")
    if isinstance(value, TLVector):
        return [to_wire(item, depth + 1) for item in value.objects]
    if isinstance(value, (VectorInt, VectorLong)):
        return value.value
    if isinstance(value, TLObject):
        # Recursive values are processed here, so cycles/depth are bounded.
        definition = value._definition
        if definition is None:
            raise UnsupportedSurfaceError("abstract TL result type cannot be serialized")
        for field in definition["params"]:
            if field["name"] not in value._values and field["type"] != "#" and "?" not in field["type"]:
                raise ValueError(f"{definition['name']}: missing required field {field['name']}")
        _boolean_masks(value._values, definition["params"], definition["name"])
        return {"_": definition["name"], **{key: to_wire(item, depth + 1) for key, item in value._values.items()}}
    if isinstance(value, bytes):
        return {"__bytes__": base64.b64encode(value).decode("ascii")}
    from virtualjava.arrays import byte_array_bytes
    byte_data = byte_array_bytes(value)
    if byte_data is not None:
        return {"__bytes__": base64.b64encode(byte_data).decode("ascii")}
    if isinstance(value, (list, tuple, MutableSequence)):
        return [to_wire(item, depth + 1) for item in value]
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value): raise TypeError("TL object keys must be strings")
        return {key: to_wire(item, depth + 1) for key, item in value.items()}
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, int):
        if not -(2 ** 63) <= value < 2 ** 63: raise OverflowError("TL integer exceeds Int64")
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    raise TypeError(f"not a TL/JSON value: {type(value).__name__}")


class Schema:
    def __init__(self, path):
        self.definitions, self.classes, self.aliases = {}, {}, {}
        self.type_bases = {}
        self._hook_names, self._canonical_hooks, self.method_names = {}, {}, set()
        path = Path(path)
        if not path.is_file():
            return
        if path.stat().st_size > 16 * 1024 * 1024: raise ValueError("TL schema metadata exceeds 16 MiB")
        metadata = json.loads(path.read_text(encoding="utf-8"))
        if metadata.get("schemaVersion") != 1: raise ValueError("unsupported TL schema version")
        self.definitions = {record["name"]: record for record in metadata["constructors"] + metadata["methods"]
                            if record.get("supported") is True}
        self.aliases = metadata.get("aliases", {})
        self.method_names = {record["name"] for record in metadata["methods"]}
        for name, aliases in metadata.get("hookNames", {}).items():
            if not isinstance(name, str) or not isinstance(aliases, list) or any(not isinstance(alias, str) for alias in aliases):
                raise ValueError("invalid generated TL hookNames table")
            self._hook_names[name] = tuple(aliases)
            for alias in aliases:
                self._canonical_hooks.setdefault(alias, set()).add(name)
        from virtualjava import register_class, register_factory, get_registered
        register_class("org.telegram.tgnet.Vector", TLVector)
        register_class("org.telegram.tgnet.Vector$Int", VectorInt)
        register_class("org.telegram.tgnet.Vector$Long", VectorLong)
        for alias, result_type in metadata.get("typeAliases", {}).items():
            cls = self.type_bases.setdefault(result_type, type(result_type.replace(".", "_"), (TLObject,), {}))
            if get_registered(alias) is None: register_class(alias, cls)
        for alias, name in self.aliases.items():
            if name not in self.definitions: continue
            fields = metadata.get("fieldAliases", {}).get(alias, {})
            register_factory(alias, lambda alias=alias, name=name, fields=fields: self.class_for(name, alias, fields))
        namespaces = {alias.rsplit("$", 1)[0] for alias in self.aliases if "$" in alias}
        for fqcn in namespaces:
            if get_registered(fqcn) is not None: continue
            def lookup(cls, member, prefix=fqcn):
                found = get_registered(prefix + "$" + member)
                if found is None: raise AttributeError(f"no schema-backed TL alias {prefix}${member}")
                return found
            meta = type("TLNamespace", (type,), {"__getattr__": lookup})
            register_class(fqcn, meta(fqcn.rsplit(".", 1)[-1], (), {}))

    def class_for(self, name, alias=None, fields=None):
        key = alias or name
        if key not in self.classes:
            definition = self.definitions.get(name)
            if definition is None: raise UnsupportedSurfaceError(f"no native TL schema constructor {name!r}")
            base = self.type_bases.get(definition["type"], TLObject)
            self.classes[key] = type((alias or name).rsplit("$", 1)[-1].replace(".", "_"), (base,), {
                "_definition": definition, "_field_aliases": dict(fields or {}),
                "_fqcn": alias or name, "constructor": definition["id"],
                "__annotations__": {field["name"]: object for field in definition["params"]},
            })
        return self.classes[key]

    def decode(self, value, depth=0):
        if depth > 64: raise ValueError("TL response nesting exceeds 64")
        if isinstance(value, list): return ArrayList(self.decode(item, depth + 1) for item in value)
        if not isinstance(value, dict): return value
        if set(value) == {"__bytes__"}: return base64.b64decode(value["__bytes__"], validate=True)
        fields = {key: self.decode(item, depth + 1) for key, item in value.items() if key != "_"}
        if "_" in value:
            name = value["_"]
            if name not in self.definitions: raise UnsupportedSurfaceError(f"no native TL schema constructor {name!r}")
            # Use an actual generated Android class identity when one is available.
            alias = next((alias for alias, target in self.aliases.items() if target == name), None)
            if alias is not None:
                from virtualjava import get_registered
                return get_registered(alias)(**fields)
            return self.class_for(name)(**fields)
        return fields

    def hook_names(self, name): return self._hook_names.get(name, ())

    def canonical_name(self, name):
        if name in self.aliases: return self.aliases[name]
        candidates = self._canonical_hooks.get(name, ())
        return next(iter(candidates)) if len(candidates) == 1 else name

    def hook_group(self, pattern):
        canonical = self.canonical_name(pattern)
        # Canonical names are the native extension of the original short-name API.
        if canonical in self.method_names or self._canonical_hooks.get(pattern, set()) & self.method_names: return "request"
        names = self.hook_names(canonical) or (pattern,)
        if any(name.startswith(("TL_updates", "TL_updateShort")) for name in names): return "updates"
        if any(name.startswith("TL_update") for name in names): return "update"
        return "request"

    def response_type(self, request_name):
        name = self.canonical_name(request_name)
        definition = self.definitions.get(name)
        if definition is None or name not in self.method_names:
            raise UnsupportedSurfaceError(f"no declared native TL response type for {request_name!r}")
        return definition["type"]

    def decode_response(self, value, result_type):
        if value is None: return None
        if result_type and result_type.startswith(("Vector<", "vector<")) and result_type.endswith(">"):
            if not isinstance(value, list): raise TypeError("declared TL Vector response must be a wire array")
            element_type = result_type[7:-1]
            items = self.decode(value)
            if element_type == "int": items = ArrayList(VectorInt(item) for item in items)
            elif element_type == "long": items = ArrayList(VectorLong._from_value(item) for item in items)
            return TLVector._from_values(items)
        return self.decode(value)

    def hook_value(self, snapshot, request_name=None):
        if not isinstance(snapshot, dict) or "tl" not in snapshot:
            return snapshot
        result_type = self.response_type(request_name) if request_name is not None else None
        value = self.decode_response(snapshot["tl"], result_type)
        return self.attach_context(value, snapshot)

    def attach_context(self, value, snapshot):
        context = freeze_context({key: item for key, item in snapshot.items() if key != "tl"})
        if isinstance(value, TLObject): object.__setattr__(value, "_tl_context", context)
        return value


def freeze_context(value):
    if isinstance(value, dict): return MappingProxyType({key: freeze_context(item) for key, item in value.items()})
    if isinstance(value, list): return tuple(freeze_context(item) for item in value)
    return value


class TLVector(TLObject):
    """The Android Vector data container, without a fabricated TL schema record."""
    _fqcn = "org.telegram.tgnet.Vector"
    constructor = 0x1cb5c415

    def __init__(self, item_deserializer=None):
        if item_deserializer is not None:
            raise UnsupportedSurfaceError("Vector stream deserializers are supplied by the native TL codec")
        super().__init__()
        object.__setattr__(self, "_objects", ArrayList())

    @classmethod
    def _from_values(cls, values):
        result = cls()
        result.objects.addAll(values)
        return result

    @property
    def objects(self): return self._objects

    def toIntArray(self): return ArrayList(item.value for item in self.objects if isinstance(item, VectorInt))


class _VectorInteger(TLObject):
    def __init__(self, value):
        super().__init__()
        self.value = value

    def __setattr__(self, name, value):
        if name == "value":
            if type(value) is not int or not -(2 ** (self._bits - 1)) <= value < 2 ** (self._bits - 1):
                raise ValueError(f"Vector primitive requires an exact Int{self._bits}")
            object.__setattr__(self, name, value)
        else: super().__setattr__(name, value)


class VectorInt(_VectorInteger):
    _fqcn = "org.telegram.tgnet.Vector$Int"
    _bits = 32


class VectorLong(_VectorInteger):
    _fqcn = "org.telegram.tgnet.Vector$Long"
    _bits = 64

    def __init__(self, high, low):
        for word in (high, low):
            if type(word) is not int or not -(2 ** 31) <= word < 2 ** 31:
                raise ValueError("Vector.Long constructor requires two Int32 words")
        super().__init__((high << 32) | (low & 0xffffffff))

    @classmethod
    def _from_value(cls, value):
        result = cls.__new__(cls)
        _VectorInteger.__init__(result, value)
        return result


TLVector.Int, TLVector.Long = VectorInt, VectorLong


class RequestToken(int):
    def __new__(cls, number, owner, native_id):
        obj = int.__new__(cls, number)
        obj.owner, obj.native_id = owner, native_id
        return obj
    def cancel(self): return self.owner.cancel(self)


class Requests:
    def __init__(self, platform, schema):
        self.platform, self.schema = platform, schema
        self.pending = {}
        self.next_id = 1

    def submit(self, member, model, callback, account):
        p = self.platform
        p.check_worker()
        result_type = self.schema.response_type(model["request"]["_"]) if member == "tlRequest" else None
        lease = p.callbacks.new(member, lambda ident: p.call("tlCancel", ident))
        with p.callbacks.lock:
            number = self.next_id
            self.next_id += 1
        def forget():
            with p.callbacks.lock:
                if self.pending.get(number) is lease: self.pending.pop(number)
        lease.on_close = forget
        def completed(response, error):
            forget()
            response, error = self.schema.decode_response(response, result_type), self.schema.decode(error)
            if callback is None:
                if error is not None: p.log(p.plugin_id, f"{member} failed: {getattr(error, 'text', error)}")
                return None
            callback(response, error) if callable(callback) else callback.run(response, error)
            return None  # RequestDelegate.run is void; never export an ignored return handle.
        try:
            wrapper = lease.wrap(completed, account=account, terminal=True)
            lease.native_owned = True
            lease.id = admitted_id(p.call(member, to_wire(model), wrapper), "requestId")
        except BaseException:
            lease.native_owned = False
            lease.close()
            raise
        with p.callbacks.lock:
            if lease.open:
                self.pending[number] = lease
        return RequestToken(number, self, lease.id)

    def cancel(self, request_id):
        self.platform.check_worker()
        if not isinstance(request_id, int) or isinstance(request_id, bool): raise TypeError("request id must be an integer token")
        with self.platform.callbacks.lock:
            lease = self.pending.get(int(request_id))
        if lease is None: return False
        if isinstance(request_id, RequestToken) and (request_id.owner is not self or request_id.native_id != lease.id): return False
        value = self.platform.call("tlCancel", lease.id)
        if not isinstance(value, dict) or type(value.get("cancelled")) is not bool:
            raise RuntimeStateError("tlCancel must return {cancelled: Bool}")
        if value["cancelled"]: lease.close()
        # False/failed cancellation leaves the completion winner and native FIFO
        # release in charge. Closing here would suppress a legitimate callback.
        return value["cancelled"]


def peer_model(peer, *, allow_secret=False):
    if isinstance(peer, dict) and set(peer) == {"type", "id"}:
        if peer["type"] not in (("user", "group", "channel", "secret") if allow_secret else ("user", "group", "channel")): raise ValueError("invalid peer type")
        result = dict(peer)
    elif isinstance(peer, TLObject):
        fields = to_wire(peer)
        kinds = {"inputPeerUser": ("user", "user_id"), "inputPeerChat": ("group", "chat_id"),
                 "inputPeerChannel": ("channel", "channel_id"), "peerUser": ("user", "user_id"),
                 "peerChat": ("group", "chat_id"), "peerChannel": ("channel", "channel_id")}
        if fields["_"] not in kinds: raise UnsupportedSurfaceError("peer needs an explicit user/group/channel identity")
        kind, key = kinds[fields["_"]]
        result = {"type": kind, "id": fields[key]}
    else:
        result = {"type": "user", "id": peer}
    if type(result["id"]) is not int or not 0 < result["id"] < 2 ** 56:
        raise ValueError("peer id must be a positive raw 56-bit id; use typed peers for groups/channels")
    if result["type"] == "secret" and result["id"] >= 2 ** 31: raise ValueError("secret chat id must fit Int32")
    return result


def install(platform, client):
    from virtualjava import register_class
    python_root = Path(__file__).resolve().parent.parent
    schema_path = python_root / "tl-schema.json"
    if not schema_path.is_file(): schema_path = python_root / "runtime/tl-schema.json"
    schema = Schema(schema_path)
    requests = Requests(platform, schema)
    platform.tl = requests

    def account_index(account, helper):
        value = client._resolve_account(account, helper)
        if type(value) is not int or not 0 <= value < 2 ** 31: raise ValueError("account must be an Int32 slot")
        return value

    def send_request(request, fn, account=None):
        account = account_index(account, "send_request")
        platform.loader.require_permission("network", "send_request")
        return requests.submit("tlRequest", {"schemaVersion": 1, "account": account, "request": to_wire(request)}, fn, account)

    class RequestDelegate(Object):
        def run(self, response, error): raise NotImplementedError("override RequestDelegate.run")
    class RequestCallback(RequestDelegate):
        _exteraless_request_delegate = True
        def __init__(self, fn, account=None): self.fn, self.account = fn, account_index(account, "RequestCallback")
        def run(self, response, error):
            with client.hook_scope(self.account): return self.fn(response, error) if self.fn is not None else None
    client.RequestCallback = RequestCallback
    client.send_request = send_request

    class Connections(Object):
        ConnectionStateConnecting = 1
        ConnectionStateWaitingForNetwork = 2
        ConnectionStateConnected = 3
        ConnectionStateConnectingToProxy = 4
        ConnectionStateUpdating = 5
        def __init__(self, account): self.account = account
        @classmethod
        def getInstance(cls, account): return cls(account_index(account, "get_connections_manager"))
        def sendRequest(self, request, callback, flags=0):
            if flags: raise UnsupportedSurfaceError("Android connection/quick-ack flags are unsupported by tlRequest")
            return send_request(request, callback, self.account)
        def cancelRequest(self, request_id, notify_server=False): return requests.cancel(request_id)
        def getCurrentTime(self):
            raise UnsupportedSurfaceError("server time requires a native account clock snapshot")
        def getConnectionState(self):
            states = {"waitingForNetwork": 2, "connecting": 1, "online": 3, "updating": 5}
            value = platform.call("nativeConnectionState", self.account)
            if value not in states: raise RuntimeStateError("nativeConnectionState returned an unknown state")
            return states[value]
    client.get_connections_manager = lambda account=None: Connections(account_index(account, "get_connections_manager"))
    register_class("org.telegram.tgnet.ConnectionsManager", Connections)
    register_class("org.telegram.tgnet.RequestDelegate", RequestDelegate)
    import base_plugin
    base_plugin.PluginServices.sendRequest = lambda account, request, callback: send_request(request, callback, account)

    def lookup_peer(peer, callback, account=None):
        account = account_index(account, "getPeer")
        return requests.submit("getPeer", {"schemaVersion": 1, "account": account, "peer": peer_model(peer, allow_secret=True)}, callback, account)
    platform.get_peer = lookup_peer

    def caption(text, parse_mode):
        if not parse_mode: return text or "", []
        from extera_utils.text_formatting import parse_text
        parsed = parse_text(str(text or ""), parse_mode, is_caption=True)
        return parsed.get("caption", ""), to_wire(parsed.get("entities", []))

    def reply(value):
        if value is None: return None
        if isinstance(value, dict):
            if set(value) - {"id", "namespace"}: raise ValueError("reply accepts only id/namespace")
            if value.get("id") is None: raise ValueError("reply needs a message id")
            model = reply(value.get("id"))
            if "namespace" in value:
                if type(value["namespace"]) is not int or value["namespace"] not in (0, 1, 2): raise ValueError("invalid reply namespace")
                model["namespace"] = value["namespace"]
            return model
        ident = value.getId() if hasattr(value, "getId") else value
        if type(ident) is not int or not 0 < ident < 2 ** 31: raise ValueError("reply must identify a positive cloud message id")
        return {"id": ident}

    def native_media(model, callback=None, account=None, *, member="sendMedia"):
        platform.check_worker()
        platform.loader.require_permission("messages.send", member)
        if not isinstance(model, dict): raise TypeError("native media requires a DTO object")
        model = dict(model)
        pinned = account_index(account if account is not None else model.get("account"), member)
        model.update(schemaVersion=1, account=pinned, peer=peer_model(model.get("peer"), allow_secret=True))
        kind = model.get("kind")
        if kind not in ("text", "photo", "video", "audio", "document", "album"):
            raise UnsupportedSurfaceError("native media requires an explicit supported kind")
        if "replyTo" in model: model["replyTo"] = reply(model["replyTo"])
        if kind == "album":
            items = model.get("items")
            if not isinstance(items, (list, tuple)) or not 2 <= len(items) <= 10: raise ValueError("album requires 2...10 items")
            if any(not isinstance(item, dict) or item.get("kind") not in ("photo", "video", "audio", "document") for item in items):
                raise ValueError("album entries require file media kinds")
            model["items"] = [dict(item) for item in items]
            files = model["items"]
        else: files = [] if kind == "text" else [model]
        from file_utils import _require_files
        for item in files:
            path = os.path.abspath(os.fspath(item["path"]))
            _require_files(path, member)
            if not os.path.isfile(path): raise FileNotFoundError(path)
            item["path"] = path
        return requests.submit(member, to_wire(model), callback, pinned)

    client.send_native_media = native_media
    client.edit_native_media = lambda model, callback=None, account=None: native_media(model, callback, account, member="editMedia")
    client.send_album = lambda peer, items, callback=None, account=None, **options: native_media(dict(options, peer=peer, kind="album", items=items), callback, account)
    client.AccountClient.send_native_media = lambda self, model, callback=None: native_media(model, callback, self.account)
    client.AccountClient.edit_native_media = lambda self, model, callback=None: native_media(model, callback, self.account, member="editMedia")
    client.AccountClient.send_album = lambda self, peer, items, callback=None, **options: native_media(dict(options, peer=peer, kind="album", items=items), callback, self.account)

    def send_media(kind, peer, path, text=None, parse_mode=None, reply_to=None, account=None, thread=None):
        platform.loader.require_permission("messages.send", "send_" + kind)
        from file_utils import _require_files
        path = os.path.abspath(os.fspath(path))
        _require_files(path, "send media")
        if not os.path.isfile(path): raise FileNotFoundError(path)
        account = account_index(account, "send_" + kind)
        text, entities = caption(text, parse_mode)
        model = {"schemaVersion": 1, "account": account, "peer": peer_model(peer),
                 "kind": kind, "path": path, "caption": text, "entities": entities}
        if reply_to is not None: model["replyTo"] = reply(reply_to)
        if thread is not None:
            model["threadId"] = thread.getId() if hasattr(thread, "getId") else int(thread)
        return requests.submit("sendMedia", model, None, account)

    def send_text(peer_id, text, replyToMsg=None, parse_mode=None, account=None):
        platform.loader.require_permission("messages.send", "send_text")
        account = account_index(account, "send_text")
        if replyToMsg is None and not parse_mode:
            return platform.call("sendMessage", peer_model(peer_id), str(text), account)
        return rich_text(peer_id, str(text), {"replyToMsg": replyToMsg}, parse_mode, account)

    def rich_text(peer, text, params, parse_mode, account):
        params = dict(params)
        text, parsed_entities = caption(text, parse_mode)
        model = {"kind": "text", "peer": peer, "caption": text}
        if "entities" in params:
            model["entities"] = to_wire(params.pop("entities"))
        elif parse_mode:
            model["entities"] = parsed_entities
        if "replyToMsg" in params: model["replyTo"] = reply(params.pop("replyToMsg"))
        if "replyToTopMsg" in params:
            top = params.pop("replyToTopMsg")
            model["threadId"] = reply(top)["id"] if top is not None else None
        for source, target in (("notify", "silent"), ("searchLinks", "disableLinkPreviews")):
            if source in params:
                value = params.pop(source)
                if type(value) is not bool: raise TypeError(f"{source} requires Bool")
                model[target] = not value
        if "scheduleDate" in params:
            date = params.pop("scheduleDate")
            if date is not None and (type(date) is not int or not 0 <= date < 2 ** 31):
                raise ValueError("scheduleDate must be a nonnegative Int32 Unix timestamp")
            model["scheduleTime"] = date or None  # Java 0 explicitly means unscheduled.
        if params.get("replyMarkup", _OMITTED) is None: params.pop("replyMarkup")
        if params: raise UnsupportedSurfaceError("unsupported SendMessageParams fields: " + ", ".join(params))
        # The native text preparation owns random IDs, local outgoing messages,
        # Updates, paid/restriction checks and origin. No getPeer/raw RPC detour.
        return native_media(model, account=account)

    def send_message(params, parse_mode=None, account=None):
        params = dict(params)
        peer = params.pop("peer", params.pop("peer_id", None))
        text = params.pop("message", None)
        account = account_index(account, "send_message")
        platform.loader.require_permission("messages.send", "send_message")
        if text is None: raise ValueError("send_message needs message text; media uses the native file helpers")
        if not params and not parse_mode: return send_text(peer, text, account=account)
        return rich_text(peer, str(text), params, parse_mode, account)

    client.send_text, client.send_message = send_text, send_message
    client.send_photo = lambda peer_id, path, caption=None, high_quality=False, parse_mode=None, replyToMsg=None, account=None: send_media(
        "document" if high_quality else "photo", peer_id, path, caption, parse_mode, replyToMsg, account)
    client.send_video = lambda peer_id, path, caption=None, parse_mode=None, replyToMsg=None, account=None: send_media(
        "video", peer_id, path, caption, parse_mode, replyToMsg, account)
    client.send_document = lambda peer_id, path, caption=None, parse_mode=None, replyToMsg=None, account=None, replyToTopMsg=None: send_media(
        "document", peer_id, path, caption, parse_mode, replyToMsg, account, replyToTopMsg)
    client.send_audio = lambda peer_id, path, caption=None, parse_mode=None, replyToMsg=None, account=None: send_media(
        "audio", peer_id, path, caption, parse_mode, replyToMsg, account)

    def edit_message(message_obj, text=None, file_path=None, with_spoiler=_OMITTED, parse_mode=None, account=None):
        if not isinstance(message_obj, dict) or "peer" not in message_obj or "id" not in message_obj:
            raise TypeError("edit_message requires an explicit native peer/id/namespace target")
        kind = message_obj.get("kind") if file_path is not None else "text"
        if kind not in ("text", "photo", "video", "audio", "document"):
            raise UnsupportedSurfaceError("file replacement requires an explicit native media kind")
        target = {"id": message_obj["id"]}
        if "namespace" in message_obj: target["namespace"] = message_obj["namespace"]
        model = {"peer": message_obj["peer"], "message": target, "kind": kind}
        if file_path is not None: model["path"] = file_path
        if with_spoiler is not _OMITTED:
            if type(with_spoiler) is not bool: raise TypeError("with_spoiler requires Bool")
            model["spoiler"] = with_spoiler
        if text is not None:
            model["caption"], entities = caption(str(text), parse_mode)
            if parse_mode: model["entities"] = entities
        # Omitted caption/entities/spoiler stay omitted. An explicitly empty
        # caption clears it; native edit preparation owns cached-text semantics.
        return native_media(model, account=account, member="editMedia")
    client.edit_message = edit_message

    class SendMessageParams(Object):
        def __init__(self, **fields): self.__dict__.update(fields)
        @classmethod
        def of(cls, text, peer): return cls(message=str(text), peer=peer)
    class SendHelper(Object):
        def __init__(self, account): self.account = account_index(account, "get_send_messages_helper")
        @classmethod
        def getInstance(cls, account): return cls(account)
        def sendMessage(self, params, text=None):
            if text is not None: return send_text(params, text, account=self.account)
            return send_message(vars(params) if isinstance(params, SendMessageParams) else params, account=self.account)
    SendHelper.SendMessageParams = SendMessageParams
    register_class("org.telegram.messenger.SendMessagesHelper", SendHelper)
    register_class("org.telegram.messenger.SendMessagesHelper$SendMessageParams", SendMessageParams)
    client.get_send_messages_helper = lambda account=None: SendHelper(account_index(account, "get_send_messages_helper"))

    class Account(Object):
        def __init__(self, account): self.currentAccount = account_index(account, "get_account_instance")
        @classmethod
        def getInstance(cls, account): return cls(account)
        def getCurrentAccount(self): return self.currentAccount
        def getConnectionsManager(self): return Connections(self.currentAccount)
        def getSendMessagesHelper(self): return SendHelper(self.currentAccount)
        def getUserConfig(self):
            from java import jclass
            return jclass("org.telegram.messenger.UserConfig").getInstance(self.currentAccount)
        def getMessagesController(self):
            from java import jclass
            return jclass("org.telegram.messenger.MessagesController").getInstance(self.currentAccount)
        def getContactsController(self): return client.get_contacts_controller(self.currentAccount)
        def getMediaDataController(self): return client.get_media_data_controller(self.currentAccount)
        def getNotificationsController(self): return client.get_notifications_controller(self.currentAccount)
        def getFileLoader(self): return client.get_file_loader(self.currentAccount)
        def getDownloadController(self): return client.get_download_controller(self.currentAccount)
        def getNotificationCenter(self): return client.get_notification_center(self.currentAccount)
    register_class("org.telegram.messenger.AccountInstance", Account)
    client.get_account_instance = lambda account=None: Account(account_index(account, "get_account_instance"))
    return requests
