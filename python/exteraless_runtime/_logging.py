"""Native structured errors with the SDK's non-throwing safe_call contract."""

import traceback


def install(platform, android, client):
    def event(level, message, phase="sdk", trace=None):
        model = {"level": level, "message": str(message), "phase": phase}
        if trace is not None: model["traceback"] = trace
        try:
            return platform.call("logEvent", model)
        except Exception:
            return platform.log(platform.plugin_id, f"[{level}] {message}" + ("\n" + trace if trace else ""))

    def safe_call(fn, *args, **kwargs):
        if fn is None:
            return None
        try:
            with platform.loader.plugin_context(platform.plugin_id):
                return fn(*args, **kwargs)
        except Exception as error:
            try:
                event("W" if isinstance(error, PermissionError) else "E", str(error), "sdk.safe_call", traceback.format_exc())
            except Exception:
                pass
            return None

    platform.log_event = event
    android.safe_call = safe_call
