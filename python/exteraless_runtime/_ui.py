"""SDK builders are Python models; every presentation/effect is native UIKit."""

import copy
import contextlib
import json
import math
import uuid

from ._callbacks import admitted_id
from ._java_types import Object, File
from ._platform import RuntimeStateError, UnsupportedSurfaceError


def _listener(listener, method, *args):
    if listener is None:
        return None
    return listener(*args) if callable(listener) else getattr(listener, method)(*args)


class Presentation:
    def __init__(self, platform, kind, model, callbacks):
        self.platform, self.kind, self.model = platform, kind, copy.deepcopy(model)
        self.callbacks = dict(callbacks)
        if "closed" in self.callbacks: raise ValueError("closed is reserved for native lease bookkeeping")
        self.lease = None

    def show(self):
        p = self.platform
        p.check_worker()
        if "closed" in self.callbacks: raise ValueError("closed is reserved for native lease bookkeeping")
        if self.lease is not None and self.lease.open:
            return self
        lease = p.callbacks.new("ui:" + self.kind, lambda ident: p.call("uiDismiss", ident))
        self.lease = lease
        try:
            def void_callback(fn):
                if not callable(fn): raise TypeError("UI callback must be callable")
                def invoke(*args):
                    fn(*args)
                    return None
                return invoke
            callbacks = {name: lease.wrap(void_callback(fn)) for name, fn in self.callbacks.items()}
            callbacks["closed"] = lease.wrap(None, terminal=True)
            lease.id = admitted_id(p.call("uiPresent", self.kind, self.model, callbacks))
            lease.native_owned = True
        except BaseException:
            lease.close()
            raise
        return self

    @property
    def id(self):
        return self.lease.id if self.lease is not None else None

    def update(self, **changes):
        self.platform.check_worker()
        model = dict(self.model, **changes)
        if self.lease is not None and self.lease.open:
            self.platform.call("uiUpdate", self.id, model)
        self.model = model
        return self

    def dismiss(self):
        self.platform.check_worker()
        if self.lease is not None and self.lease.open:
            self.platform.call("uiDismiss", self.id)
        # Native queues dismiss/closed then releases on this owner's worker.
        return self

    def isShowing(self):
        if self.lease is None or not self.lease.open:
            return False
        state = self.platform.call("uiState", self.id)
        if not isinstance(state, dict) or type(state.get("visible")) is not bool:
            raise RuntimeStateError("uiState must return native visible: Bool")
        return state["visible"]


class Button(Object):
    def __init__(self, dialog, which): self.dialog, self.which = dialog, which
    def setText(self, text): self._set(text=str(text))
    def setTextColor(self, color):
        if type(color) is not int or not -(2 ** 31) <= color < 2 ** 32: raise ValueError("color must be a 32-bit ARGB integer")
        self._set(color=color)
    def setEnabled(self, value): self._set(enabled=bool(value))
    def _set(self, **values):
        buttons = copy.deepcopy(self.dialog.model.get("buttons", []))
        for button in buttons:
            if button["which"] == self.which:
                button.update(values)
                self.dialog.update(buttons=buttons)
                return
        raise LookupError(f"dialog has no button {self.which}")


class NativeDialog(Presentation, Object):
    def getButton(self, which):
        return Button(self, which) if any(item["which"] == which for item in self.model.get("buttons", [])) else None
    def setCancelable(self, value): self.update(cancelable=bool(value))
    def setCanceledOnTouchOutside(self, value): self.update(cancelOnTouchOutside=bool(value))
    def setProgress(self, value):
        value = int(value)
        if not 0 <= value <= 100: raise ValueError("progress must be 0...100")
        self.update(progress=value)


def _points(value, name, maximum, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError(f"{name} requires a number, not Bool or an Android object")
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be {minimum}...{maximum} native points")
    return value


def _dimension(value, name):
    if value is None or isinstance(value, str) and value in ("fill", "wrap"):
        return value
    if type(value) is int and value in (-1, -2): return value
    return _points(value, name, 8192)


def _insets(value, name):
    if isinstance(value, dict):
        if set(value) - {"left", "top", "right", "bottom"}: raise ValueError(f"unknown {name} fields")
        return {key: _points(item, name, 512) for key, item in value.items()}
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        raise TypeError(f"{name} requires left, top, right, bottom")
    return [_points(item, name, 512) for item in value]


def _layout(value):
    if not isinstance(value, dict): raise UnsupportedSurfaceError("use portable layout parameters")
    if set(value) - {"width", "height", "weight", "alignment", "margins"}: raise ValueError("unknown native layout fields")
    result = copy.deepcopy(value)
    for key in ("width", "height"):
        if key in result: result[key] = _dimension(result[key], "layout." + key)
    if result.get("weight") is not None: _points(result["weight"], "layout.weight", 1000)
    if result.get("margins") is not None: result["margins"] = _insets(result["margins"], "layout.margins")
    if result.get("alignment") is not None and result["alignment"] not in ("fill", "start", "center", "end"):
        raise ValueError("unsupported native layout alignment")
    return result


def _font(value):
    if isinstance(value, str): return value
    if not isinstance(value, dict): raise UnsupportedSurfaceError("use a native font name or font descriptor")
    if set(value) - {"name", "size", "weight"}: raise ValueError("unknown native font fields")
    for key in ("name", "weight"):
        if value.get(key) is not None and not isinstance(value[key], str): raise TypeError(f"font.{key} requires text")
    if value.get("size") is not None: _points(value["size"], "font.size", 128, 1)
    return copy.deepcopy(value)  # Actual named-font/weight availability belongs to native.


class Widget(Object):
    kind = "view"
    _next_id = 0
    def __init__(self, context=None):
        Widget._next_id += 1
        self.model = {"type": self.kind, "id": f"widget_{Widget._next_id}"}
        self.children, self.changed = [], None
    def to_model(self):
        value = copy.deepcopy(self.model)
        if self.children: value["children"] = [child.to_model() for child in self.children]
        return value
    def _set(self, **values):
        previous = dict(self.model)
        self.model.update(copy.deepcopy(values))
        try:
            if self.changed is not None: self.changed()
        except BaseException:
            self.model.clear(); self.model.update(previous)
            raise
    def bind(self, changed):
        self.changed = changed
        for child in self.children: child.bind(changed)
    def accept_values(self, values):
        key = self.model.get("key", self.model["id"])
        if key in values: self.model["value"] = values[key]
        for child in self.children: child.accept_values(values)
    def setText(self, text): self._set(**{"value" if self.kind == "input" else "text": str(text)})
    def getText(self): return self.model.get("value" if self.kind == "input" else "text", "")
    def setHint(self, text): self._set(hint=str(text))
    def setEnabled(self, value): self._set(enabled=bool(value))
    def setVisibility(self, value):
        names = {0: "visible", 4: "invisible", 8: "gone"}
        if type(value) is not int or value not in names: raise ValueError("visibility must be VISIBLE=0, INVISIBLE=4 or GONE=8")
        self._set(visibility=names[value])
    def setPadding(self, left, top, right, bottom):
        self._set(padding=_insets([left, top, right, bottom], "padding"))
    def setLayoutParams(self, value):
        if isinstance(value, LayoutParams): value = value.to_model()
        self._set(layout=_layout(value))
    def setTypeface(self, face): self._set(font=_font(face))
    def setTextSize(self, size):
        font = self.model.get("font", {"name": "system"})
        if isinstance(font, str): font = {"name": font}
        self._set(font=_font(dict(font, size=size)))


class LayoutParams(Object):
    MATCH_PARENT, WRAP_CONTENT = -1, -2
    def __init__(self, width=-1, height=-2, weight=0):
        self.width, self.height, self.weight = _dimension(width, "width"), _dimension(height, "height"), _points(weight, "weight", 1000)
        self.margins = [0, 0, 0, 0]
    def setMargins(self, left, top, right, bottom): self.margins = _insets([left, top, right, bottom], "margins")
    def to_model(self):
        return _layout({"width": self.width, "height": self.height, "weight": self.weight, "margins": self.margins})


class ImageView(Widget):
    kind = "image"
    def setImageResource(self, name):
        if not isinstance(name, str): raise UnsupportedSurfaceError("ImageView requires a named UIKit/bundle image")
        self._set(image=name)


class TextView(Widget): kind = "text"
class EditText(Widget): kind = "input"


class LinearLayout(Widget):
    kind = "column"
    VERTICAL, HORIZONTAL = 1, 0
    def setOrientation(self, value):
        if type(value) is not int or value not in (0, 1): raise ValueError("orientation must be HORIZONTAL=0 or VERTICAL=1")
        self._set(type="column" if value == 1 else "row")
    def addView(self, view, *layout):
        if not isinstance(view, Widget): raise TypeError("addView requires a ported widget")
        if len(layout) == 1: view.setLayoutParams(layout[0])
        elif len(layout) == 2: view.setLayoutParams(LayoutParams(*layout))
        elif layout: raise UnsupportedSurfaceError("use LayoutParams or width/height in native logical points")
        self.children.append(view)
        try:
            if self.changed: self.bind(self.changed); self.changed()
        except BaseException:
            self.children.pop(); view.bind(None)
            raise


class PlatformContext(Object):
    def __init__(self, platform): self.platform = platform
    def getFilesDir(self): return File(self.platform.getFilesDir())
    def getCacheDir(self): return File(self.platform.getCacheDir())
    def getApplicationContext(self): return self
    def getSystemService(self, name):
        if name == "clipboard": return Clipboard(self.platform)
        raise UnsupportedSurfaceError(f"Android system service {name!r} is unavailable")
    def startActivity(self, intent):
        if not isinstance(intent, Intent): raise TypeError("startActivity requires a ported Intent")
        if intent.action == Intent.ACTION_VIEW:
            return self.platform.call("openURL", str(intent.data))
        if intent.action in (Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE):
            streams = intent.extras.get(Intent.EXTRA_STREAM, [])
            if not isinstance(streams, (list, tuple)): streams = [streams]
            from urllib.parse import unquote, urlsplit
            files = []
            for item in streams:
                text = str(item)
                if text.startswith("file:"): text = unquote(urlsplit(text).path)
                files.append(text)
            model = {"text": intent.extras.get(Intent.EXTRA_TEXT), "files": files or None,
                     "title": intent.extras.get(Intent.EXTRA_SUBJECT), "mimeType": intent.mime}
            return self.platform.present("share", {key: value for key, value in model.items() if value is not None})
        raise UnsupportedSurfaceError(f"Android intent action is not mapped to iOS: {intent.action}")


class Intent(Object):
    ACTION_VIEW, ACTION_SEND, ACTION_SEND_MULTIPLE = "android.intent.action.VIEW", "android.intent.action.SEND", "android.intent.action.SEND_MULTIPLE"
    EXTRA_TEXT, EXTRA_STREAM, EXTRA_SUBJECT = "android.intent.extra.TEXT", "android.intent.extra.STREAM", "android.intent.extra.SUBJECT"
    FLAG_ACTIVITY_NEW_TASK = 0x10000000
    def __init__(self, action=None, data=None): self.action, self.data, self.extras, self.mime = action, data, {}, None
    def setAction(self, action): self.action = action; return self
    def getAction(self): return self.action
    def setData(self, data): self.data = data; return self
    def getData(self): return self.data
    def setType(self, mime): self.mime = str(mime); return self
    def getType(self): return self.mime
    def putExtra(self, key, value): self.extras[str(key)] = value; return self
    def getStringExtra(self, key): return self.extras.get(key)
    def addFlags(self, flags):
        if flags & ~self.FLAG_ACTIVITY_NEW_TASK: raise UnsupportedSurfaceError("Android activity task flags are not iOS scene options")
        return self  # The native app presenter owns the current scene.
    setFlags = addFlags
    @staticmethod
    def createChooser(intent, title):
        if intent.action not in (Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE): raise UnsupportedSurfaceError("only native share choosers are supported")
        intent.extras.setdefault(Intent.EXTRA_SUBJECT, str(title))
        return intent


class Clipboard(Object):
    def __init__(self, platform): self.platform = platform
    def setPrimaryClip(self, clip): self.platform.call("addToClipboard", clip.text)


class ClipData(Object):
    def __init__(self, text): self.text = str(text)
    @classmethod
    def newPlainText(cls, label, text): return cls(text)


class SettingsTargetError(ValueError):
    """Exact original key/link_alias lookup failed, before native presentation."""

    def __init__(self, code):
        self.code = code
        super().__init__(f"SettingsTarget.{code}")


def resolve_settings_target(rows, target):
    """Return the containing page and row, using the ORIGINAL SDK JSON identities.

    No trimming, case folding, Unicode normalization, prefix match or plugin ID
    lookup. A row matching both its key and alias is one match, not two.
    """
    if target is None: return {"pagePath": [], "rowId": None}
    if not isinstance(target, str): raise SettingsTargetError("invalid")
    target = str.__str__(target)  # Real string contents, not a subclass's equality hook.
    if not target or "\0" in target:
        raise SettingsTargetError("invalid")
    try: size = len(target.encode("utf-8"))
    except UnicodeEncodeError: raise SettingsTargetError("invalid") from None
    if size > 256: raise SettingsTargetError("tooLong")
    matches, count = [], 0
    def visit(items, path):
        nonlocal count
        if not isinstance(items, list) or len(path) > 16:
            raise ValueError("Settings document exceeds 16 levels")
        for row in items:
            count += 1
            if count > 1000 or not isinstance(row, dict): raise ValueError("Invalid or oversized settings document")
            ident = row.get("row_id")
            if not isinstance(ident, str) or not ident or len(ident.encode("utf-8")) > 256:
                raise ValueError("Settings target requires SDK row_id")
            if target == row.get("link_alias") or target == row.get("key"):
                matches.append({"pagePath": list(path), "rowId": ident})
            if row.get("sub_page") is not None: visit(row["sub_page"], path + [ident])
    visit(rows, [])
    if not matches: raise SettingsTargetError("unknown")
    if len(matches) != 1: raise SettingsTargetError("ambiguous")
    return matches[0]


def _settings_json(value):
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if len(raw.encode("utf-8")) > 1024 * 1024: raise ValueError("Settings response exceeds 1 MiB")
    return raw


class _SettingsPage:
    """Owner-worker snapshot. SDK string IDs never enter the C handle namespace.

    The original serializer and callback dispatch run against an isolated copy of
    its PluginRecord. A later create_settings cannot replace this page's targets.
    A zero-handle SDK lease supplies unload cleanup; native owns the page UUID.
    """

    def __init__(self, platform, ident, account):
        platform.check_worker()
        self.platform, self.id, self.account = platform, ident, account
        self.owner = platform.owner_token
        self.record = copy.copy(platform.loader.plugins[platform.plugin_id])
        self.record.click_callbacks, self.record.change_callbacks, self.record.custom_views = {}, {}, {}
        self.views, self.widget_routes, self.click_views, self.keys = {}, {}, {}, set()
        self.source_rows, self.rows = [], []
        self.lease = platform.callbacks.new("settings-page")
        self.lease.on_close = self._release

    def _release(self):
        pages = getattr(self.platform, "settings_pages", {})
        if pages.get(self.id) is self: pages.pop(self.id)
        self.views.clear(); self.widget_routes.clear(); self.click_views.clear(); self.keys.clear()
        self.source_rows, self.rows = [], []
        if self.record is not None:
            self.record.click_callbacks.clear(); self.record.change_callbacks.clear(); self.record.custom_views.clear()
        self.record = None

    def close(self): self.lease.close()

    def check(self):
        self.platform.check_worker()
        if (not self.lease.open or not self.platform.callbacks.active
                or self.lease.generation != self.platform.callbacks.generation
                or self.owner != self.platform.owner_token or self.record is None):
            raise RuntimeStateError("Settings page belongs to a closed owner/read generation")

    @contextlib.contextmanager
    def scope(self):
        from . import _scope
        self.check()
        loader, ident = self.platform.loader, self.platform.plugin_id
        original = loader.plugins.get(ident)
        if original is None or original.instance is not self.record.instance:
            raise RuntimeStateError("Settings page belongs to a replaced plugin")
        loader.plugins[ident] = self.record
        try:
            with _scope(self.platform, self.account): yield
        finally:
            if loader.plugins.get(ident) is self.record: loader.plugins[ident] = original

    def build(self, *, manager):
        from . import dispatch_json
        try:
            with self.scope():
                raw = dispatch_json("create_settings", json.dumps({"account": self.account}))
                if len(raw.encode("utf-8")) > 1024 * 1024: raise ValueError("Settings response exceeds 1 MiB")
                rows = json.loads(raw)
                if not isinstance(rows, list): raise TypeError("Settings response must be an array")
                self.source_rows = copy.deepcopy(rows)
                self.rows = self.prepare(rows, manager=manager)
                # Widgets needed by callbacks are retained explicitly. Factories,
                # failed rows and unused Android objects are not page resources.
                self.record.custom_views.clear()
                if len(self.record.click_callbacks) + len(self.record.change_callbacks) + len(self.widget_routes) > 128:
                    raise ValueError("Settings callbacks exceed 128 entries")
                _settings_json(self.rows)
            return self
        except BaseException:
            self.close()
            raise

    def prepare(self, rows, *, manager):
        count, widgets = [0], [0]
        def visit(items, depth):
            if depth > 16 or not isinstance(items, list): raise ValueError("Settings document exceeds 16 levels")
            for row in items:
                count[0] += 1
                if count[0] > 1000 or not isinstance(row, dict): raise ValueError("Settings response exceeds 1,000 rows")
                row.setdefault("row_id", "settings_error_" + str(count[0]))
                if row.get("type") in ("switch", "selector", "input", "edittext", "edit_text", "slider"):
                    self.keys.add(row["key"])
                if row.get("type") == "custom":
                    ident = row["row_id"]
                    before = set(self.widget_routes)
                    try:
                        item = self.record.custom_views[row["view_id"]]
                        view = self.platform.loader._build_custom_view(item, self.platform.ui_context)
                        if not isinstance(view, Widget): raise UnsupportedSurfaceError("Custom requires a portable native Widget; Android View is unavailable")
                        model = self.prepare_widget(view, ident, widgets)
                        self.views[ident] = view
                        for name in ("callback_id", "long_callback_id"):
                            if row.get(name): self.click_views[row[name]] = view
                        if manager:
                            row["widget_json"] = _settings_json(model)
                            row.pop("view_id", None)
                        else:
                            retained = {key: value for key, value in row.items() if key in ("row_id", "callback_id", "long_callback_id", "sub_page")}
                            if retained.get("callback_id") and model.get("type") not in ("text", "header", "image"):
                                raise UnsupportedSurfaceError("Portable container click needs an actionable child widget")
                            row.clear(); row.update(model); row.update(retained)
                            row["id"] = ident
                    except Exception as error:
                        for route in set(self.widget_routes) - before: self.widget_routes.pop(route)
                        self.views.pop(ident, None)
                        for name in ("callback_id", "long_callback_id"):
                            callback = row.pop(name, None)
                            self.record.click_callbacks.pop(callback, None); self.click_views.pop(callback, None)
                        # A typed, visible error row, with no materialization code
                        # deferred to UIImage creation or layout on main.
                        message = f"{type(error).__name__}: {error}"[:4096]
                        row.pop("view_id", None); row.pop("widget_json", None)
                        if manager: row["custom_error"] = message
                        else:
                            row.clear(); row.update(type="text", row_id=ident, text=message, red=True)
                if not manager:
                    row.pop("integral", None)
                    row.pop("backup_exportable", None)
                    secret = row.pop("is_secret", False) or row.get("sensitive", False)
                    row.pop("sensitive", None)
                    if secret and row.get("type") in ("input", "edittext", "edit_text"): row["secure"] = True
                    row.pop("link_alias", None)
                    # Navigation is in the serializer's row identity space. Alias
                    # is a lookup key, never an alternate native widget identity.
                    row["id"] = row["row_id"]
                    if row.get("icon") is not None and not isinstance(row["icon"], str):
                        raise UnsupportedSurfaceError("Settings icons require native names")
                if row.get("sub_page") is not None: visit(row["sub_page"], depth + 1)
        visit(rows, 0)
        return rows

    def prepare_widget(self, view, row_id, count):
        seen, nodes, callbacks = set(), [], {}
        def bounded(widget, depth):
            count[0] += 1
            if depth > 8 or count[0] > 512 or id(widget) in seen:
                raise ValueError("Custom widgets exceed 8 levels/512 nodes or contain a cycle")
            seen.add(id(widget))
            nodes.append(widget)
            callbacks[id(widget)] = {field: widget.model[field] for field in ("callback", "callback_id", "long_callback_id") if field in widget.model}
            for child in widget.children:
                if not isinstance(child, Widget): raise UnsupportedSurfaceError("Custom child is not a portable Widget")
                bounded(child, depth + 1)
        bounded(view, 0)
        # The existing builder deep-copies its DTO. Deep-copying a bound method
        # would clone its plugin instance (or fail on a lock). Lift callbacks out
        # first and restore the exact objects on this same owner worker.
        try:
            for widget in nodes:
                for field in callbacks[id(widget)]: widget.model.pop(field)
            model = view.to_model()
        finally:
            for widget in nodes: widget.model.update(callbacks[id(widget)])
        identifiers, keys = set(), set()
        def prepare(raw, widget, depth=0):
            if not isinstance(raw, dict) or "__handle__" in raw or depth > 8:
                raise UnsupportedSurfaceError("Custom model must be a bounded widget DTO")
            ident = raw.get("id")
            if not isinstance(ident, str) or not ident or len(ident.encode("utf-8")) > 256 or ident in identifiers:
                raise ValueError("Custom widget requires unique bounded IDs")
            identifiers.add(ident)
            kind = raw.get("type")
            editable = kind in ("input", "edittext", "edit_text", "toggle", "switch", "selector", "slider")
            key = raw.get("key", ident)
            if editable:
                if not isinstance(key, str) or not key or key in keys: raise ValueError("Duplicate Custom value key")
                keys.add(key)
            for field, event in (("callback", "change" if editable else "action"), ("long_callback_id", "longAction")):
                original = callbacks[id(widget)]
                value = original.get("callback", original.get("callback_id")) if field == "callback" else original.get(field)
                if field == "callback": raw.pop("callback_id", None)
                if value is None and not (editable and event == "change"): continue
                callback = value
                if isinstance(value, str):
                    callback = (self.record.change_callbacks if event == "change" else self.record.click_callbacks).get(value)
                    if callback is None: raise LookupError("Custom references an unknown SDK callback ID")
                if callback is not None and not callable(callback): raise TypeError("Custom callback must be callable or an owned SDK string ID")
                token = "cw_" + self.id + "_" + str(len(self.widget_routes))
                raw[field] = token
                self.widget_routes[token] = (row_id, ident, event, widget, callback, raw)
            children = raw.get("children", [])
            if not isinstance(children, list) or len(children) != len(widget.children):
                raise ValueError("Custom children must come from the portable Widget builder")
            if raw.get("sub_page") is not None:
                raise UnsupportedSurfaceError("Custom subpages use ui.settings.Custom.create_sub_fragment")
            for child, child_view in zip(children, widget.children): prepare(child, child_view, depth + 1)
        prepare(model, view)
        return model

    def event(self, event):
        if not isinstance(event, dict): raise TypeError("Settings event must be an object")
        with self.scope():
            loader, ident = self.platform.loader, self.platform.plugin_id
            kind = event.get("kind")
            if kind == "change":
                key = event["key"]
                if key not in self.keys: raise LookupError("Setting is not in this page snapshot")
                loader.notify_setting_changed(ident, key, _settings_json(event["value"]))
            elif kind == "click":
                callback = event["callbackId"]
                if callback not in self.record.click_callbacks: raise LookupError("Callback is not in this page snapshot")
                loader.dispatch_setting_click(ident, callback, self.click_views.get(callback))
            elif kind == "widget":
                route = self.widget_routes.get(event.get("callbackId"))
                if route is None: raise LookupError("Custom callback belongs to another page/read")
                row, widget_id, name, view, callback, model = route
                if (event.get("rowId"), event.get("widgetId"), event.get("event")) != (row, widget_id, name):
                    raise RuntimeStateError("Custom callback does not belong to this widget event")
                value = view
                if name == "change":
                    value = event["value"]
                    _validate_settings_widget_value(model, value)
                    view.model["value"] = value
                if callback is not None: loader._call_with_optional_arg(callback, value)
            else: raise ValueError("Unknown settings page event")
        return None


def _validate_settings_widget_value(model, value):
    kind = model.get("type")
    if kind in ("input", "edittext", "edit_text"):
        valid = isinstance(value, str) and len(value) <= model.get("max_length", 16384)
    elif kind in ("switch", "toggle"): valid = type(value) is bool
    elif kind == "selector": valid = type(value) is int and 0 <= value < len(model.get("items", []))
    elif kind == "slider":
        valid = type(value) in (int, float) and math.isfinite(value) and model.get("min", 0) <= value <= model.get("max", 100)
    else: valid = False
    if not valid: raise ValueError("Custom value violates its native widget model")


def read_settings_page_json(page_id, payload_json):
    """Host-only read body; invoked under the existing create_settings batch guard."""
    from . import _runtime, _settings_account
    platform = _runtime(loaded=True)
    if not isinstance(page_id, str) or str(uuid.UUID(page_id)) != page_id.lower(): raise ValueError("Invalid settings page UUID")
    payload = json.loads(payload_json)
    account = _settings_account(payload["account"])
    if account is None: raise ValueError("Manager settings require a captured SDK account")
    pages = platform.settings_pages
    if page_id in pages: raise RuntimeStateError("Settings page UUID cannot be reused")
    page = _SettingsPage(platform, page_id, account).build(manager=True)
    pages[page_id] = page
    return _settings_json(page.rows)


def settings_page_event_json(page_id, event_json):
    from . import _runtime
    platform = _runtime(loaded=True)
    if len(event_json.encode("utf-8")) > 512 * 1024: raise ValueError("Settings event exceeds 512 KiB")
    page = platform.settings_pages.get(page_id)
    if page is None: raise RuntimeStateError("Settings page has been released")
    page.event(json.loads(event_json))
    return "null"


def release_settings_page_json(page_id):
    from . import _runtime
    platform = _runtime()
    page = getattr(platform, "settings_pages", {}).get(page_id)
    if page is not None: page.close()
    return "null"


class _SettingsPresentation(Presentation):
    """Portable settings swap callback snapshots only on a native commit ACK.

    uiUpdate admission is asynchronous. One candidate and its unique completion
    lease stay live until native settles it; native events carry their committed
    snapshot ID. The ACK and handle release use the existing owner FIFO.
    """

    def __init__(self, platform, read_page):
        page, model = read_page()
        self.page, self._read_page = page, read_page
        self._pending, self._revision, self._closed = None, 0, False
        super().__init__(platform, "settings", model, {
            "change": self._receive, "action": self._receive,
            "longAction": self._receive, "refresh": self._refresh})

    def show(self):
        self.page.check()
        try:
            super().show()
            self.lease.on_close = self._close_pages
            return self
        except BaseException:
            self._close_pages()
            raise

    def _close_pages(self):
        self._closed = True
        self.page.close()
        pending, self._pending = self._pending, None
        if pending is not None:
            pending["page"].close()
            pending["lease"].close()

    def _event_page(self, event):
        self.platform.check_worker()
        if (self._closed or not isinstance(event, dict) or event.get("id") != self.id
                or event.get("_uiSettingsSnapshot") != self.page.id
                or type(event.get("_uiRevision")) is not int or event["_uiRevision"] != self._revision):
            raise RuntimeStateError("Settings event belongs to an uncommitted or retired snapshot")
        self.page.check()
        return self.page

    def _receive(self, event):
        page = self._event_page(event)
        callback = event.get("callbackId")
        if callback in page.widget_routes:
            row, widget_id, name, _, _, _ = page.widget_routes[callback]
            return page.event(dict(event, kind="widget", rowId=row, widgetId=widget_id, event=name))
        if "value" in event: return page.event(dict(event, kind="change"))
        return page.event(dict(event, kind="click"))

    def _refresh(self, event):
        self._event_page(event)
        self._require_idle()
        page, model = self._read_page()
        return self._stage(page, model)

    def _require_idle(self):
        self.platform.check_worker()
        if self._closed or self.lease is None or not self.lease.open:
            raise RuntimeStateError("Settings presentation is closed")
        if self._pending is not None:
            raise RuntimeStateError("Settings update is awaiting native commit")

    def update(self, **changes):
        self._require_idle()
        # Cosmetic updates keep their callback snapshot but share the same native
        # revision/ACK protocol. Callers cannot replace the snapshot identity.
        if changes.get("settingsSnapshotId", self.page.id) != self.page.id:
            raise RuntimeStateError("Settings snapshot identity is managed by refresh")
        return self._stage(self.page, dict(self.model, **changes))

    def _stage(self, page, model):
        try:
            self._require_idle()
            lease = self.platform.callbacks.new("settings-update")
        except BaseException:
            if page is not self.page: page.close()
            raise
        pending = {"page": page, "model": model, "lease": lease, "previous": self.page.id}
        self._pending = pending
        def discarded():
            if self._pending is pending: self._pending = None
            if self.page is not page: page.close()
        lease.on_close = discarded
        try:
            completion = lease.wrap(lambda event: self._settle(pending, event), terminal=True)
            result = self.platform.call("uiUpdate", self.id, model, {
                "previousSnapshotId": self.page.id, "snapshotId": page.id, "completion": completion})
            lease.id = admitted_id(result)
            lease.native_owned = True
        except BaseException:
            lease.close()
            raise
        return self  # Admission only: self.page/model/revision still describe S1.

    def _settle(self, pending, event):
        self.platform.check_worker()
        if self._closed or self._pending is not pending: return None
        committed = event.get("committed") if isinstance(event, dict) else None
        if (type(committed) is not bool or event.get("event") != "settingsUpdate"
                or event.get("id") != self.id or event.get("updateId") != pending["lease"].id
                or event.get("previousSnapshotId") != pending["previous"]
                or event.get("snapshotId") != pending["page"].id
                or type(event.get("_uiRevision")) is not int
                or event["_uiRevision"] != self._revision + (1 if committed else 0)):
            raise RuntimeStateError("Invalid native settings update acknowledgement")
        self._pending = None
        if committed:
            previous, self.page = self.page, pending["page"]
            self.model, self._revision = pending["model"], event["_uiRevision"]
            if previous is not self.page: previous.close()
        elif pending["page"] is not self.page:
            pending["page"].close()
        return None


def install(platform, android, client):
    from virtualjava import register_class
    from ui import alert, bulletin
    context = PlatformContext(platform)
    platform.ui_context = context

    class Builder(Object):
        def __init__(self, context=None, style=0, resources_provider=None):
            if resources_provider is not None or type(style) is not int:
                raise UnsupportedSurfaceError("Android resources providers are not UIKit resources")
            styles = {0: "message", 2: "loading", 3: "spinner"}
            if style not in styles: raise ValueError("unsupported alert style")
            self.model = {"style": styles[style], "cancelable": style == 0, "buttons": []}
            self.listeners, self.view, self._view_height, self._native_dialog = {}, None, -2, None

        def _set(self, **changes):
            platform.check_worker()
            if self._native_dialog is not None:
                self._native_dialog.update(**changes)
                self.model = copy.deepcopy(self._native_dialog.model)
            else: self.model.update(copy.deepcopy(changes))
            return self
        def _listen(self, name, listener, method):
            platform.check_worker()
            self.listeners[name] = (listener, method)
            return self
        def _view_model(self):
            value = self.view.to_model()
            if self._view_height != -2: value["layout"] = dict(value.get("layout", {}), height=self._view_height)
            return value
        def setTitle(self, value): return self._set(title=str(value))
        def setMessage(self, value): return self._set(message=str(value))
        def setView(self, value, height=-2):
            if not isinstance(value, Widget): raise UnsupportedSurfaceError("set_view requires a ported widget DTO")
            height = _dimension(height, "view.height")
            candidate = value.to_model()
            if height != -2: candidate["layout"] = dict(candidate.get("layout", {}), height=height)
            self._set(view=candidate)
            if self.view is not None: self.view.bind(None)
            self.view, self._view_height = value, height
            self.view.bind(lambda: self._set(view=self._view_model()))
            return self
        def setItems(self, items, *args):
            items = list(map(str, items))
            if len(args) == 1: rows, listener = items, args[0]
            elif len(args) == 2:
                icons, listener = list(args[0]), args[1]
                if len(icons) != len(items): raise ValueError("item/icon counts differ")
                rows = [{"text": text, "icon": icon_value(icon)} for text, icon in zip(items, icons)]
            else: raise TypeError("setItems expects items, optional named icons, and a listener")
            self._set(items=rows)
            return self._listen("item", listener, "onClick")
        def _button(self, name, which, text, listener):
            current = self._native_dialog.model if self._native_dialog is not None else self.model
            buttons = copy.deepcopy(current["buttons"])
            button = next((item for item in buttons if item["which"] == which), None)
            if button is None: buttons.append({"which": which, "text": str(text)})
            else: button["text"] = str(text)
            self._set(buttons=buttons)
            return self._listen(name, listener, "onClick")
        def setPositiveButton(self, text, listener): return self._button("positive", -1, text, listener)
        def setNegativeButton(self, text, listener): return self._button("negative", -2, text, listener)
        def setNeutralButton(self, text, listener): return self._button("neutral", -3, text, listener)
        def setOnDismissListener(self, value): return self._listen("dismiss", value, "onDismiss")
        def setOnCancelListener(self, value): return self._listen("cancel", value, "onCancel")
        def setOnBackButtonListener(self, value): return self._listen("back", value, "onClick")
        def setDimEnabled(self, value): return self._set(dimEnabled=bool(value))
        def setBlurredBackground(self, value, blur_behind=True):
            return self._set(blurredBackground=bool(value), blurBehind=bool(blur_behind))
        def setMessageTextViewClickable(self, value): return self._set(messageClickable=bool(value))
        def create(self):
            platform.check_worker()
            if self._native_dialog is not None: return self._native_dialog
            dialog = NativeDialog(platform, "alert", self.model, {})
            self._native_dialog = dialog
            def handler(event_name):
                def receive(event):
                    if not isinstance(event, dict): raise TypeError("UI callback must contain an event object")
                    if self.view is not None: self.view.accept_values(event.get("values", {}))
                    listener, method = self.listeners.get(event_name, (None, "onClick"))
                    args = (dialog, event.get("which", -1)) if method == "onClick" else (dialog,)
                    return _listener(listener, method, *args)
                return receive
            # Listener changes only replace Python targets. Native uiUpdate never
            # receives additional handles, including newly added item/buttons.
            dialog.callbacks = {name: handler(name) for name in ("positive", "negative", "neutral", "item", "dismiss", "cancel", "back")}
            def changed(event):
                if self.view is not None: self.view.accept_values({event["key"]: event["value"]})
            dialog.callbacks["change"] = changed
            return dialog
        def show(self): return self.create().show()

    register_class("org.telegram.ui.ActionBar.AlertDialog$Builder", Builder)
    class Dialog(NativeDialog):
        BUTTON_POSITIVE, BUTTON_NEGATIVE, BUTTON_NEUTRAL = -1, -2, -3
        def __init__(self, context=None, style=0):
            if type(style) is not int or style not in (0, 2, 3): raise ValueError("unsupported alert style")
            super().__init__(platform, "alert", {"style": {0: "message", 2: "loading", 3: "spinner"}[style], "cancelable": style == 0}, {})
        def setTitle(self, text): self.update(title=str(text)); return self
        def setMessage(self, text): self.update(message=str(text)); return self
    Dialog.Builder = Builder
    register_class("org.telegram.ui.ActionBar.AlertDialog", Dialog)

    class BottomSheetBuilder(Builder):
        def __init__(self, context=None, need_focus=False): super().__init__(context)
        def create(self):
            dialog = super().create()
            dialog.kind = "bottomSheet"
            dialog.model.pop("style", None)
            return dialog
        def setCustomView(self, view): return self.setView(view)
        def selectedPos(self, position):
            if type(position) is not int: raise TypeError("selectedIndex must be an integer")
            return self._set(selectedIndex=position)
    class BottomSheet:
        Builder = BottomSheetBuilder
    register_class("org.telegram.ui.ActionBar.BottomSheet$Builder", BottomSheetBuilder)
    register_class("org.telegram.ui.ActionBar.BottomSheet", BottomSheet)
    for fqcn, cls in {"android.widget.TextView": TextView, "android.widget.EditText": EditText,
                      "android.widget.LinearLayout": LinearLayout, "android.widget.ImageView": ImageView,
                      "android.widget.LinearLayout$LayoutParams": LayoutParams, "android.content.ClipData": ClipData,
                      "android.content.Intent": Intent}.items():
        register_class(fqcn, cls)

    def ui_sync(fn):
        platform.check_worker()
        return fn()  # Builder/data operations only; native provider dispatches UIKit to main.
    alert._run_sync = ui_sync
    alert._post = ui_sync
    alert._default_context = lambda: context
    original_init = alert.AlertDialogBuilder.__init__
    def alert_init(builder, context=None, alert_type=0, resources_provider=None, *, progress_style=None):
        if type(alert_type) is not int or progress_style is not None and type(progress_style) is not int:
            raise TypeError("alert style must be an integer, not Bool")
        original_init(builder, context, alert_type, resources_provider, progress_style=progress_style)
    alert.AlertDialogBuilder.__init__ = alert_init
    def red_button(builder, which):
        if builder._dialog is None: raise RuntimeStateError("create/show the dialog before coloring its button")
        button = builder._dialog.getButton(int(which))
        if button is None: raise LookupError(which)
        button._set(destructive=True, color=None)
        return builder
    alert.AlertDialogBuilder.make_button_red = red_button
    def blurred_background(builder, blur, blur_behind_if_possible=True):
        platform.check_worker()
        builder._builder.setBlurredBackground(blur, blur_behind_if_possible)
        return builder
    alert.AlertDialogBuilder.set_blurred_background = blurred_background
    def named_items(builder, items, listener, icons=None):
        platform.check_worker()
        def clicked(dialog, which): return alert.safe_call(listener, builder, which)
        if icons is None: builder._builder.setItems(items, clicked)
        else: builder._builder.setItems(items, list(icons), clicked)
        return builder
    alert.AlertDialogBuilder.set_items = named_items
    android.get_context = lambda: context
    android.copy_to_clipboard = lambda text: platform.call("addToClipboard", str(text))

    def show_bulletin(text, style="info", *, title=None, subtitle=None, duration=1500, button=None, callbacks=None, icon=None):
        model = {"text": str(text), "style": style, "durationMs": int(duration)}
        for key, value in (("title", title), ("subtitle", subtitle), ("buttonText", button), ("icon", icon)):
            if value is not None: model[key] = value
        return Presentation(platform, "bulletin", model, callbacks or {}).show()

    def icon_value(value):
        if value is None or type(value) is int and value == 0: return None
        if not isinstance(value, str): raise UnsupportedSurfaceError(f"Android drawable id {value} has no UIKit mapping")
        return value

    helper = bulletin.BulletinHelper
    helper.show_info = staticmethod(lambda message, fragment=None: show_bulletin(message))
    helper.show_error = staticmethod(lambda message, fragment=None: show_bulletin(message, "error"))
    helper.show_success = staticmethod(lambda message, fragment=None: show_bulletin(message, "success"))
    helper.show_simple = staticmethod(lambda text, icon_res_id, fragment=None, duration=None:
                                     show_bulletin(text, duration=duration or 1500, icon=icon_value(icon_res_id)))
    helper.show_two_line = staticmethod(lambda title, subtitle, icon_res_id, fragment=None, duration=None:
                                       show_bulletin(title, subtitle=subtitle, duration=duration or 1500, icon=icon_value(icon_res_id)))
    helper.show_with_button = staticmethod(lambda text, icon_res_id, button_text, on_click, fragment=None, duration=5000:
        show_bulletin(text, duration=duration, button=button_text, icon=icon_value(icon_res_id),
                      callbacks={"action": lambda event: on_click() if on_click else None}))
    helper.show_undo = staticmethod(lambda text, on_undo, on_action=None, subtitle=None, fragment=None:
        show_bulletin(text, "undo", subtitle=subtitle, duration=5000,
                      callbacks={"undo": lambda event: on_undo() if on_undo else None,
                                 "action": lambda event: on_action() if on_action else None}))
    helper.show_copied_to_clipboard = staticmethod(lambda fragment=None: show_bulletin("Copied to clipboard", "success"))
    helper.show_link_copied = staticmethod(lambda fragment=None: show_bulletin("Link copied", "success"))
    helper.show_file_saved_to_gallery = staticmethod(lambda fragment=None: show_bulletin("Saved to gallery", "success"))
    helper.show_file_saved_to_downloads = staticmethod(lambda file_type="DOCUMENT", amount=1, fragment=None:
                                                       show_bulletin(f"Saved to downloads ({int(amount)})", "success"))

    class Toast(Object):
        LENGTH_SHORT, LENGTH_LONG = 0, 1
        @staticmethod
        def makeText(context, text, duration):
            return Presentation(platform, "toast", {"text": str(text), "durationMs": 2750 if duration else 1500}, {})
    register_class("android.widget.Toast", Toast)
    platform.present = lambda kind, model, callbacks=None: Presentation(platform, kind, model, callbacks or {}).show()

    platform.settings_pages = {}

    def show_settings(title=None, target=None):
        platform.check_worker()
        from . import _settings_account
        fragment = platform.call("uiActiveFragment")
        if not isinstance(fragment, dict) or not isinstance(fragment.get("id"), str):
            raise RuntimeStateError("Settings require a current native presenter")
        account = _settings_account(fragment["account"])
        if account is None: raise RuntimeStateError("Settings require a captured native account")
        def read_page():
            page = _SettingsPage(platform, str(uuid.uuid4()), account).build(manager=False)
            try:
                location = resolve_settings_target(page.source_rows, target)
                model = {"title": title or platform.plugin_id, "rows": page.rows,
                         "pagePath": location["pagePath"], "sourceId": fragment["id"], "settingsSnapshotId": page.id}
                if location["rowId"] is not None: model["targetRowId"] = location["rowId"]
                return page, model
            except BaseException:
                page.close()
                raise
        return _SettingsPresentation(platform, read_page).show()

    platform.show_settings = show_settings
    platform.share = lambda text=None, files=None, title=None: platform.present(
        "share", {key: value for key, value in {"text": text, "files": files, "title": title}.items() if value is not None})

    class Fragment(Object):
        def __init__(self, descriptor): self.descriptor = descriptor
        def getContext(self): return context
        def getParentActivity(self): return context
        def getCurrentAccount(self):
            account = self.descriptor["account"]
            if type(account) is not int or not 0 <= account < 2 ** 31: raise RuntimeStateError("fragment account must be an Int32 slot")
            return account
        def presentFragment(self, page):
            value = page.to_model() if hasattr(page, "to_model") else page
            if not isinstance(value, dict): raise TypeError("presentFragment requires a portable route/page")
            if value.get("sourceId", self.descriptor["id"]) != self.descriptor["id"]:
                raise RuntimeStateError("navigation source cannot be retargeted")
            return platform.call("uiNavigate", dict(value, sourceId=self.descriptor["id"]))

    from ._codec import Snapshot
    class MenuMessageSnapshot(Snapshot):
        _methods = frozenset(("getId", "getDialogId", "isOutOwner", "isPhoto", "isVideo", "isVoice", "isMusic",
                              "isDocument", "isSticker", "isRoundVideo", "isGif", "isAnimatedSticker"))
        def __getattr__(self, name):
            value = super().__getattr__(name)
            return (lambda: value) if name in self._methods else value
    def menu_context(event):
        result = Snapshot(event)
        if isinstance(result.get("fragment"), dict): result["fragment"] = Fragment(result["fragment"])
        result["context"] = context
        if isinstance(result.get("message"), dict): result["message"] = MenuMessageSnapshot(result["message"])
        return result
    platform.menu_context = menu_context

    def active_fragment():
        descriptor = platform.call("uiActiveFragment")
        if descriptor is None: return None
        if not isinstance(descriptor, dict): raise RuntimeStateError("uiActiveFragment must return object or null")
        return Fragment(descriptor)
    client.get_last_fragment = active_fragment
    client.get_current_fragment = active_fragment
    android.get_activity = lambda: context if active_fragment() is not None else None
    android.share_text = lambda text, title=None: platform.share(text=str(text), title=title)
    android.share_file = lambda path, title=None: platform.share(files=[str(path)], title=title)

    from ui import settings
    class PluginItemFactory(Object):
        @classmethod
        def getInstance(cls): return cls()
        @staticmethod
        def create(factory, args=None): return settings.Custom(factory=factory, factory_args=tuple(args) if args else None)
    register_class("app.exteraless.plugins.models.PluginItemFactory", PluginItemFactory)
