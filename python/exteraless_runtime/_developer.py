"""SDK developer seams backed by the opt-in native manager's listener.

No socket, Python thread, session credential or privileged command dispatcher is
created here. The native provider admits owner-scoped requests; only an observed
NWListener-ready snapshot makes start() succeed. Install does not start anything.
"""

from ._elyx_helpers import dev_command
from ._platform import RuntimeStateError, UnsupportedSurfaceError


def _debugger_unavailable(request):
    return {"ok": False, "error": (
        "debugpy listen/attach is unavailable in iOS OWN_GIL interpreters "
        "(allow_fork=false, allow_exec=false, allow_daemon_threads=false); "
        "no debugger listener was started")}


def _native_command_only(command):
    def unavailable(request):
        return {"ok": False, "error": (
            f"dev_server.{command} requires the authenticated native developer "
            "service; an interpreter-local dispatch token grants no manager authority")}
    return unavailable


class NativeDeveloperServer:
    def __init__(self, platform, server):
        self.platform, self.server = platform, server

    def _require(self):
        platform = self.platform
        platform.check_worker()
        if platform.owner_token is None:
            raise RuntimeStateError("developer controls require the bound native owner epoch")
        if not platform.hasPermission(platform.plugin_id, "settings"):
            raise PermissionError("native developer controls require settings permission")

    def _call(self, member):
        self._require()
        if not self.platform.supported(member):
            raise UnsupportedSurfaceError(f"Runtime.{member}: native developer UI provider is not installed")
        return self.platform.call(member)

    def _state(self):
        state = self._call("getDeveloperServerState")
        if (not isinstance(state, dict) or set(state) != {"ready", "enabled", "status"}
                or type(state["ready"]) is not bool or type(state["enabled"]) is not bool
                or not isinstance(state["status"], str)
                or (state["ready"] and not state["enabled"])):
            raise RuntimeStateError("native developer state must be {ready: Bool, enabled: Bool, status: String}")
        return state

    def _request(self, member):
        reply = self._call(member)
        if (not isinstance(reply, dict) or set(reply) != {"accepted", "operationId"}
                or reply["accepted"] is not True or not isinstance(reply["operationId"], str)
                or not reply["operationId"]):
            raise RuntimeStateError(f"Runtime.{member} did not admit its native operation")

    def start(self):
        """True only for native readiness; False/pending/failure remains retryable."""
        self.platform.check_worker()
        self.platform.loader._dev_server_started = False
        try:
            state = self._state()
            if not state["ready"] and state["enabled"]:
                # Retry an already opted-in native service. This request cannot
                # enable developer mode; the main-actor gate is checked again.
                self._request("requestDeveloperServerStart")
                state = self._state()
            self.platform.loader._dev_server_started = state["ready"]
            if not state["ready"]:
                self.server._log(f"native developer server is not ready: {state['status']}")
            return state["ready"]
        except Exception as error:
            self.server._log(f"native developer server start failed: {type(error).__name__}: {error}")
            return False

    def start_from_loader(self):
        """Keep the SDK's void, never-raise wrapper, without a stale once latch."""
        try:
            self.start()
        except Exception as error:
            self.server._log(f"native developer server start failed: {type(error).__name__}: {error}")
        return None

    def stop(self):
        """Admit developer-mode off through native controls; completion is native."""
        self._request("requestDeveloperServerStop")
        self.platform.loader._dev_server_started = False
        return None


def install(platform):
    import dev_server

    controller = NativeDeveloperServer(platform, dev_server)
    dev_server.start = controller.start
    dev_server.stop = controller.stop
    platform.loader.start_dev_server = controller.start_from_loader
    platform.loader._dev_server_started = False
    dev_server._cmd_elyx = dev_command
    dev_server._cmd_start_debugger = _debugger_unavailable
    dev_server._cmd_stop_debugger = _debugger_unavailable
    dev_server._COMMANDS["start_debugger"] = _debugger_unavailable
    dev_server._COMMANDS["stop_debugger"] = _debugger_unavailable
    for command in ("get_plugins", "enable_plugin", "disable_plugin", "reload_plugin", "write_plugin", "remove_plugin"):
        dev_server._COMMANDS[command] = _native_command_only(command)
    return controller
