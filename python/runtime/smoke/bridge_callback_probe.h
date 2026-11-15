#ifndef EXL_BRIDGE_CALLBACK_PROBE_H
#define EXL_BRIDGE_CALLBACK_PROBE_H

/* Fresh-process, two-worker OWN_GIL probe of the real native dispatcher.
 * python_root is the repository/bundled python/ directory (virtualjava only;
 * no plugins, SDK, network or external corpus). Caller enforces <=30 seconds.
 * Retains the 169-call rollback/transport suite and checks C-owned immutable
 * owner epochs (including parent/child isolation and all seven bound ops).
 * Link _exteraless_bridge.c, register_bridge.c, engine.c, cpython312_compat.c
 * and bridge_callback_probe.c with the matching CPython 3.12 library.
 * Define EXL_BRIDGE_CALLBACK_PROBE_MAIN for the standalone host executable. */
int EXLRunBridgeCallbackProbe(const char *home, const char *stdlib_path,
                               const char *dynload_path, const char *executable_path,
                               const char *python_root, const char *report_path);

#endif
