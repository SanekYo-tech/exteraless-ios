#ifndef EXL_PYTHON_BRIDGE_H
#define EXL_PYTHON_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Register the built-in bridge before Py_InitializeFromConfig. Returns -1
 * if Python is already initialized or registration failed. No Python headers
 * are exposed to the Swift caller of this function. */
int EXLRegisterPythonBridge(void);

/* UTF-8, with explicit byte counts (excluding the convenience trailing NUL).
 * The dispatcher receives borrowed inputs valid only until it returns. It
 * MUST copy its JSON reply with EXLPythonBridgeBufferCopy, never return a
 * borrowed Swift buffer or memory from a different CRT. The bridge owns and
 * frees the response on EVERY return path, including a nonzero status. */
typedef struct {
    char *bytes;
    size_t count;
} EXLPythonBridgeBuffer;

/* The destination must be zero-initialized or previously freed. These two
 * functions use the bridge's own malloc/free and do not call Python. */
int EXLPythonBridgeBufferCopy(EXLPythonBridgeBuffer *output,
                            const char *bytes, size_t count);
void EXLPythonBridgeBufferFree(EXLPythonBridgeBuffer *buffer);

/* Synchronous Python -> host transport. Called under the CURRENT
 * interpreter's GIL on its calling worker, never while a registry lock is
 * held. Different OWN_GIL interpreters can call concurrently. Return 0 with
 * a BridgeServices reply: {"ok":true,"value":...} or
 * {"ok":false,"error":{"kind":"...","message":"..."}}. Nonzero status,
 * a pending Python exception, or a malformed reply is a bridge error.
 *
 * plugin_id is taken from per-interpreter xt_set_plugin_id state. The bridge
 * also overwrites request["pluginId"] with that ID before serialization.
 * request["ownerToken"] is supplied ONLY from per-interpreter C state, bound
 * by Python xt_set_owner_token(str) after xt_set_plugin_id: 1..256 UTF-8 bytes,
 * no NUL, immutable (the same value is idempotent). If unbound, the request has
 * NO ownerToken, even if Python supplied one. The coordinator binds a random
 * UUID per interpreter generation before SDK bind_owner_json/load; Swift must
 * validate that epoch against its captured owner before admitting work/effects.
 * This JSON field adds no callback ABI argument. An old interpreter keeps its
 * own old token; there is no lookup of another interpreter's current token.
 * Neither input may be retained. Python callbacks must be scheduled by the
 * host to their captured owner's worker using pluginId/epoch/handle; do not enter Python on
 * main, acquire the main GIL, or use PyGILState_Ensure for reverse calls. */
typedef int (*EXLPythonBridgeDispatcher)(void *context,
                                       const char *request, size_t request_count,
                                       const char *plugin_id, size_t plugin_id_count,
                                       EXLPythonBridgeBuffer *response);
typedef void (*EXLPythonBridgeContextRelease)(void *context);

/* Process-wide, explicit installation; safe before Python initialization.
 * Only one dispatcher can be installed. Returns 0 on success, -1 for invalid
 * arguments, -2 if occupied, -3 on allocation failure. On success the
 * registration owns context until release_context(context); on failure it
 * does NOT take ownership. release_context may be NULL for static contexts.
 * Explicit xt_register_service entries override this default transport, so
 * existing test services remain usable. Production installs no mock. */
int EXLPythonBridgeInstallDispatcher(EXLPythonBridgeDispatcher dispatcher,
                                     void *context,
                                     EXLPythonBridgeContextRelease release_context);

/* Detaches only the matching (dispatcher, context) pair: 0 removed, -1 not
 * matched. Prevents new calls and never waits. In-flight calls keep the old
 * context alive; its release runs once after the LAST call, outside the lock,
 * on whichever thread drains it (possibly the caller here). That release
 * must not use Python. A coordinator normally holds its binding for the whole
 * host lifetime and uninstalls after its workers stop. */
int EXLPythonBridgeUninstallDispatcher(EXLPythonBridgeDispatcher dispatcher,
                                       void *context);

/* Owner-only handle release. Caller MUST already hold the owner's GIL with
 * its thread state attached, and select the correct xt_set_interpreter_id
 * realm if using that desktop test API. Never acquires/switches a GIL.
 * Returns 1 removed, 0 absent, -1 with a Python exception, or -2 when no
 * thread state is attached (no Python exception can be set in that case).
 * ctypes desktop callers must use PYFUNCTYPE/PyDLL, not CFUNCTYPE/CDLL.
 * Detached/UI callers must enqueue xt_release_handle on the owner's worker.
 * Numeric handles alone do not identify an interpreter. */
int xt_host_release_handle(int64_t handle);

#ifdef __cplusplus
}
#endif
#endif
