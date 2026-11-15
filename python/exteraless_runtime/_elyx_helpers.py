"""Argument-shape compatibility for the preserved Elyx command handler."""


def dev_command(request):
    """Called inside dev_server.dispatch's existing authentication boundary."""
    try:
        import elyx_runtime
    except ImportError:
        return {"ok": False, "error": "Elyx runtime unavailable"}
    handler = getattr(elyx_runtime, "handle_dev_command", None)
    if handler is None:
        return {"ok": False, "error": "Elyx runtime has no handle_dev_command entry point"}
    command = request.get("@")
    if not isinstance(command, str) or not command:
        return {"ok": False, "error": 'missing "@" command'}
    # Framing and authentication belong to dispatch, not the Elyx action body.
    params = {key: value for key, value in request.items() if key not in ("@", "#", "token")}
    result = handler(command, params)
    return dict(result) if isinstance(result, dict) else {}
