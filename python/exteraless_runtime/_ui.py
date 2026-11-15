"""SDK builders are Python models; every presentation/effect is native UIKit."""

import copy
import json
import math

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

    def show_settings(title=None):
        def prepare(items):
            for row in items:
                row.pop("integral", None)  # Derived from the native slider min/max/step.
                row.pop("backup_exportable", None)
                secret = row.pop("is_secret", False) or row.get("sensitive", False)
                row.pop("sensitive", None)
                if secret and row.get("type") in ("input", "edittext", "edit_text"): row["secure"] = True
                alias = row.pop("link_alias", None)
                if alias is not None: row["id"] = alias
                if row.get("icon") is not None:
                    row["icon"] = icon_value(row["icon"])
                if row.get("type") == "custom":
                    item = platform.loader.plugins[platform.plugin_id].custom_views[row["view_id"]]
                    view = platform.loader._build_custom_view(item, context)
                    if not isinstance(view, Widget): raise UnsupportedSurfaceError("Custom requires a portable native widget")
                    retained = {key: value for key, value in row.items() if key in ("row_id", "id", "callback_id", "long_callback_id", "sub_page")}
                    row.clear()
                    row.update(view.to_model(), **retained)
                prepare(row.get("sub_page", []))
        def read_rows():
            rows = json.loads(platform.loader.get_settings_json(platform.plugin_id))
            prepare(rows)
            return rows
        def changed(event):
            platform.loader.notify_setting_changed(platform.plugin_id, event["key"], json.dumps(event["value"]))
        def action(event): platform.loader.dispatch_setting_click(platform.plugin_id, event["callbackId"])
        def refresh(event):
            record = platform.loader.plugins[platform.plugin_id]
            previous = (record.click_callbacks, record.change_callbacks, record.custom_views)
            try: presentation.update(rows=read_rows())
            except BaseException:
                record.click_callbacks, record.change_callbacks, record.custom_views = previous
                raise
        presentation = Presentation(platform, "settings", {"title": title or platform.plugin_id, "rows": read_rows()},
                                    {"change": changed, "action": action, "longAction": action, "refresh": refresh})
        return presentation.show()

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
