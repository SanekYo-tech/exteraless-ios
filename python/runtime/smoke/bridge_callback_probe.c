#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "EXLPythonBridge.h"
#include "EXLPythonEngine.h"
#include "bridge_callback_probe.h"

typedef struct ProbeContext ProbeContext;
#define PROBE_OWNER_TOKEN_BYTES 256
typedef struct {
    ProbeContext *context;
    int index, failed, started, rollback_checked, owner_checked, owner_bound, bulk_checked;
    unsigned long owner;
    int64_t reference, python_id;
    int64_t last_rejected_handle;
    unsigned int operations, calls;
    unsigned int bound_operations, bound_calls, unbound_calls, baseline_calls, bulk_calls;
    unsigned int terminal_mask, terminal_finalizers, terminal_attempts;
    unsigned int terminal_rejected, terminal_admitted, terminal_faults;
    unsigned int terminal_created, terminal_freed;
    char owner_token[PROBE_OWNER_TOKEN_BYTES + 1];
    PyThread_type_lock ready, proceed, done;
} ProbeWorker;

struct ProbeContext {
    const char *python_root;
    ProbeWorker workers[2];
    /* Written by the last callback (or uninstall), read after worker join. */
    int released;
};

static const char *const plugin_ids[] = {"bridge-probe-1-\xcf\x80", "bridge-probe-2-\xcf\x80"};
/* Fixed test vectors only; production epochs come from the coordinator's UUID
 * generator. The non-ASCII suffix tests the exact 256 UTF-8-byte boundary. */
static const char *const owner_prefixes[] = {
    "db1f2f0c-a2d1-42c0-a1cf-925d0c8ba8dc", "c972eb2a-585f-4d7a-90de-e0c85ca0b7cd"
};
static const char parent_owner_token[] = "13bb53be-5d06-4f4b-8116-e0df82fb9139";
static const char *const operations[] = {
    "construct", "call", "call_instance", "get", "get_instance", "set", "set_instance"
};

static int copy_reply(EXLPythonBridgeBuffer *response, const char *json) {
    return EXLPythonBridgeBufferCopy(response, json, strlen(json));
}

static int integer_reply(EXLPythonBridgeBuffer *response, int64_t value) {
    char json[96];
    snprintf(json, sizeof(json), "{\"ok\":true,\"value\":%lld}", (long long)value);
    return copy_reply(response, json);
}

static int64_t marker_handle(PyObject *value) {
    PyObject *id = value && PyDict_Check(value) ? PyDict_GetItemString(value, "__handle__") : NULL;
    return id && PyLong_Check(id) ? PyLong_AsLongLong(id) : 0;
}

static void release_context(void *opaque) {
    ProbeContext *context = opaque;
    context->released++;
}

enum { TERMINAL_API_COUNT = 27, NOTE_FINALIZER = 27, NOTE_ADMISSION = 28, NOTE_FAULT = 29 };
#define TERMINAL_API_MASK ((1u << TERMINAL_API_COUNT) - 1)
#define PROBE_OBSERVER "exteraless.probe.clear.observer"
#define PROBE_PAYLOAD "exteraless.probe.clear.payload"

/* Only native counters survive Py_EndInterpreter. No child PyObject is retained
 * by the driver or queried/decref'd after interpreter destruction. */
static void terminal_payload_freed(PyObject *capsule) {
    PyObject *exception = PyErr_GetRaisedException();
    ProbeWorker *worker = PyCapsule_GetPointer(capsule, PROBE_PAYLOAD);
    if (worker) worker->terminal_freed++;
    PyErr_SetRaisedException(exception);
}

static PyObject *new_terminal_payload(PyObject *self, PyObject *unused) {
    ProbeWorker *worker = PyCapsule_GetPointer(self, PROBE_OBSERVER);
    (void)unused;
    if (!worker) return NULL;
    PyObject *payload = PyCapsule_New(worker, PROBE_PAYLOAD, terminal_payload_freed);
    if (payload) worker->terminal_created++;
    return payload;
}

static PyObject *note_terminal_result(PyObject *self, PyObject *args) {
    ProbeWorker *worker = PyCapsule_GetPointer(self, PROBE_OBSERVER);
    int event, value;
    if (!worker || !PyArg_ParseTuple(args, "ii", &event, &value)) return NULL;
    if (PyThread_get_thread_ident() != worker->owner) worker->terminal_faults++;
    if (event >= 0 && event < TERMINAL_API_COUNT) {
        if (value == 1) worker->terminal_mask |= 1u << event;
        else worker->terminal_faults++;
    } else if (event == NOTE_FINALIZER) {
        worker->terminal_finalizers++;
    } else if (event == NOTE_ADMISSION) {
        worker->terminal_attempts++;
        if (value == 1) worker->terminal_rejected++;
        else worker->terminal_admitted++;
    } else {
        worker->terminal_faults++;
    }
    Py_RETURN_NONE;
}

static PyObject *force_terminal_clear(PyObject *bridge, PyObject *unused) {
    PyModuleDef *definition = PyModule_GetDef(bridge);
    (void)unused;
    if (!definition || !definition->m_clear) {
        PyErr_SetString(PyExc_RuntimeError, "probe bridge has no module clear slot");
        return NULL;
    }
    /* Called by a separate C test function, NOT inside native_dispatch_request
     * or a handle transaction. Repeat to check idempotent clear/free cleanup. */
    if (definition->m_clear(bridge) < 0 || definition->m_clear(bridge) < 0) return NULL;
    if (xt_host_release_handle(0) != -1 || !PyErr_ExceptionMatches(PyExc_RuntimeError)) {
        PyErr_SetString(PyExc_AssertionError, "host release did not reject a cleared bridge");
        return NULL;
    }
    PyErr_Clear();
    Py_RETURN_NONE;
}

static PyMethodDef clear_probe_methods[] = {
    {"_probe_terminal_note", note_terminal_result, METH_VARARGS, NULL},
    {"_probe_terminal_payload", new_terminal_payload, METH_NOARGS, NULL},
    {"_probe_terminal_clear", force_terminal_clear, METH_NOARGS, NULL},
};

static int install_clear_helpers(ProbeWorker *worker) {
    PyObject *observer = PyCapsule_New(worker, PROBE_OBSERVER, NULL);
    PyObject *bridge = PyImport_ImportModule("_exteraless_bridge");
    PyObject *main = PyImport_AddModule("__main__");
    PyObject *globals = main ? PyModule_GetDict(main) : NULL;
    int status = -1;
    if (!observer || !bridge || !globals) goto done;
    for (size_t i = 0; i < sizeof(clear_probe_methods) / sizeof(clear_probe_methods[0]); i++) {
        PyObject *function = PyCFunction_New(&clear_probe_methods[i], i == 2 ? bridge : observer);
        if (!function) goto done;
        int rc = PyDict_SetItemString(globals, clear_probe_methods[i].ml_name, function);
        Py_DECREF(function);
        if (rc < 0) goto done;
    }
    status = 0;
done:
    Py_XDECREF(bridge);
    Py_XDECREF(observer);
    return status;
}

/* A real process-wide C function, not a Python/ctypes callback. Python C API
 * use here is deliberate: it must see the SAME worker/interpreter/GIL as the
 * caller. No Python references are stored in the shared native context. */
static int dispatch(void *opaque, const char *request_bytes, size_t request_count,
                    const char *plugin_id, size_t plugin_count,
                    EXLPythonBridgeBuffer *response) {
    ProbeContext *context = opaque;
    ProbeWorker *worker = NULL;
    PyObject *json = NULL, *loads = NULL, *dumps = NULL, *text = NULL;
    PyObject *request = NULL, *envelope = NULL, *serialized = NULL, *identity = NULL;
    int status = -10;
    for (int i = 0; i < 2; i++) {
        if (plugin_count == strlen(plugin_ids[i]) && !memcmp(plugin_id, plugin_ids[i], plugin_count))
            worker = &context->workers[i];
    }
    if (!worker || PyThread_get_thread_ident() != worker->owner ||
        !request_bytes || request_count > (size_t)PY_SSIZE_T_MAX ||
        memchr(request_bytes, 0, request_count)) return -11;
    int64_t python_id = PyInterpreterState_GetID(PyInterpreterState_Get());
    if (python_id <= 0 || (worker->python_id && worker->python_id != python_id)) return -12;
    worker->python_id = python_id;
    worker->calls++;
    json = PyImport_ImportModule("json");
    loads = json ? PyObject_GetAttrString(json, "loads") : NULL;
    dumps = json ? PyObject_GetAttrString(json, "dumps") : NULL;
    text = PyUnicode_DecodeUTF8(request_bytes, (Py_ssize_t)request_count, "strict");
    request = loads && text ? PyObject_CallOneArg(loads, text) : NULL;
    identity = PyUnicode_DecodeUTF8(plugin_id, (Py_ssize_t)plugin_count, "strict");
    if (!request || !PyDict_Check(request) || !identity || !dumps) goto done;
    PyObject *injected = PyDict_GetItemString(request, "pluginId");
    PyObject *op = PyDict_GetItemString(request, "op");
    PyObject *fqcn = PyDict_GetItemString(request, "fqcn");
    PyObject *member = PyDict_GetItemString(request, "member");
    if (!injected || PyObject_RichCompareBool(identity, injected, Py_EQ) != 1 ||
        !op || !PyUnicode_Check(op) || !fqcn || !PyUnicode_Check(fqcn) ||
        PyUnicode_CompareWithASCIIString(fqcn, "exteraless.probe.Native") != 0) goto done;
    PyObject *owner_token = PyDict_GetItemString(request, "ownerToken");
    if (worker->owner_bound) {
        Py_ssize_t owner_count = 0;
        const char *owner_bytes = owner_token && PyUnicode_CheckExact(owner_token)
            ? PyUnicode_AsUTF8AndSize(owner_token, &owner_count) : NULL;
        if (!owner_bytes || owner_count != PROBE_OWNER_TOKEN_BYTES ||
            memcmp(owner_bytes, worker->owner_token, PROBE_OWNER_TOKEN_BYTES)) {
            status = -14;
            goto done;
        }
        worker->bound_calls++;
    } else {
        if (owner_token != NULL) { status = -15; goto done; }
        worker->unbound_calls++;
    }
    int operation = -1;
    for (int i = 0; i < 7; i++) {
        if (PyUnicode_CompareWithASCIIString(op, operations[i]) == 0) operation = i;
    }
    if (operation < 0) goto done;
    worker->operations |= 1u << operation;
    if (worker->owner_bound) worker->bound_operations |= 1u << operation;
    const char *method = member && PyUnicode_Check(member) ? PyUnicode_AsUTF8(member) : "";
    if (!method) goto done;
    if (!strcmp(method, "armClearProbe")) {
        if (install_clear_helpers(worker) == 0)
            status = copy_reply(response, "{\"ok\":true,\"value\":null}");
        goto done;
    }
    PyObject *arguments = PyDict_GetItemString(request, "args");
    PyObject *first = arguments && PyList_Check(arguments) && PyList_GET_SIZE(arguments)
        ? PyList_GET_ITEM(arguments, 0) : NULL;
    if (!strcmp(method, "rejectHandles") || (operation == 0 && marker_handle(first) > 0)) {
        worker->last_rejected_handle = marker_handle(first);
        if (!worker->last_rejected_handle)
            worker->last_rejected_handle = marker_handle(PyDict_GetItemString(request, "value"));
        if (!worker->last_rejected_handle) {
            PyObject *receiver = PyDict_GetItemString(request, "instance");
            if (receiver && PyLong_Check(receiver)) worker->last_rejected_handle = PyLong_AsLongLong(receiver);
        }
        status = copy_reply(response, "{\"ok\":false,\"error\":{\"kind\":\"CallbackBudget\",\"message\":\"transaction rejected\"}}");
        goto done;
    }
    if (!strcmp(method, "lastRejectedHandle")) {
        status = integer_reply(response, worker->last_rejected_handle);
        goto done;
    }
    if (!strcmp(method, "retainHandle")) {
        int64_t handle = marker_handle(first);
        if (handle <= 0) goto done;
        status = integer_reply(response, handle);
        goto done;
    }
    if (!strcmp(method, "completeProbeHandle")) {
        if (!first || !PyLong_Check(first)) goto done;
        int64_t handle = PyLong_AsLongLong(first);
        if (PyErr_Occurred()) goto done;
        status = integer_reply(response, xt_host_release_handle(handle));
        goto done;
    }
    if (operation == 2 || operation == 4 || operation == 6) {
        PyObject *instance = PyDict_GetItemString(request, "instance");
        long long handle = instance ? PyLong_AsLongLong(instance) : 0;
        if (handle != -7001 && handle != -7002) goto done;
    }
    if (!strcmp(method, "denied")) {
        status = copy_reply(response, "{\"ok\":false,\"error\":{\"kind\":\"SecurityError\",\"message\":\"native denied \xcf\x80\"}}");
        goto done;
    }
    if (!strcmp(method, "badJSON")) {
        status = copy_reply(response, "{broken");
        goto done;
    }
    if (!strcmp(method, "badEnvelope")) {
        status = copy_reply(response, "{\"ok\":1,\"value\":0}");
        goto done;
    }
    if (!strcmp(method, "badTag")) {
        status = copy_reply(response, "{\"ok\":true,\"value\":{\"__bytes__\":\"***\"}}");
        goto done;
    }
    if (!strcmp(method, "dangling")) {
        status = copy_reply(response, "{\"ok\":true,\"value\":{\"__handle__\":-9999}}");
        goto done;
    }
    if (!strcmp(method, "nulReply")) {
        const char counted[] = "{\"ok\":true,\"value\":9}\0trailer";
        status = EXLPythonBridgeBufferCopy(response, counted, sizeof(counted) - 1);
        goto done;
    }
    if (!strcmp(method, "rcFailure") || !strcmp(method, "pending")) {
        status = copy_reply(response, "{\"ok\":true,\"value\":null}");
        if (!strcmp(method, "pending")) PyErr_SetString(PyExc_ValueError, "native pending exception");
        else status = 23; /* A response allocated on failure must still be freed. */
        goto done;
    }
    if (!strcmp(method, "release")) {
        PyObject *args = PyDict_GetItemString(request, "args");
        if (!args || !PyList_Check(args) || PyList_GET_SIZE(args) != 1) goto done;
        long long handle = PyLong_AsLongLong(PyList_GET_ITEM(args, 0));
        if (PyErr_Occurred() || xt_host_release_handle(handle) != 1) goto done;
        status = copy_reply(response, "{\"ok\":true,\"value\":true}");
        goto done;
    }
    if (!strcmp(method, "detach")) {
        worker->baseline_calls++; /* Original 169-call suite's final native call. */
        if (context->released || EXLPythonBridgeUninstallDispatcher(dispatch, context) != 0 ||
            context->released) goto done; /* Context must stay pinned until return. */
        status = copy_reply(response, "{\"ok\":true,\"value\":\"drained\"}");
        goto done;
    }
    if (operation == 0 || !strcmp(method, "newHandle")) {
        status = copy_reply(response, operation == 0
            ? "{\"ok\":true,\"value\":{\"__handle__\":-7001,\"__fqcn__\":\"exteraless.probe.Native\"}}"
            : "{\"ok\":true,\"value\":{\"__handle__\":-7002,\"__fqcn__\":\"exteraless.probe.Native\"}}");
        /* Constructor args must also reach the callback. */
        if (operation == 0) {
            PyObject *args = PyDict_GetItemString(request, "args");
            PyObject *kwargs = PyDict_GetItemString(request, "kwargs");
            if (!args || !PyList_Check(args) || PyList_GET_SIZE(args) != 1 ||
                !kwargs || !PyDict_Check(kwargs) || PyDict_Size(kwargs) != 0) status = -13;
        }
        goto done;
    }
    if (operation == 5 || operation == 6) {
        PyObject *value = PyDict_GetItemString(request, "value");
        PyObject *blob = value && PyDict_Check(value) ? PyDict_GetItemString(value, "__bytes__") : NULL;
        if (!blob || !PyUnicode_Check(blob) || PyUnicode_CompareWithASCIIString(blob, "AP8=")) goto done;
    }
    envelope = Py_BuildValue("{s:O,s:{s:O,s:O,s:L}}", "ok", Py_True, "value",
                             "request", request, "context", identity, "interpreter", (long long)python_id);
    serialized = envelope ? PyObject_CallOneArg(dumps, envelope) : NULL;
    if (serialized) {
        Py_ssize_t count;
        const char *bytes = PyUnicode_AsUTF8AndSize(serialized, &count);
        if (bytes) status = EXLPythonBridgeBufferCopy(response, bytes, (size_t)count);
    }
done:
    Py_XDECREF(serialized);
    Py_XDECREF(envelope);
    Py_XDECREF(identity);
    Py_XDECREF(request);
    Py_XDECREF(text);
    Py_XDECREF(dumps);
    Py_XDECREF(loads);
    Py_XDECREF(json);
    return status;
}

static void problem(ProbeWorker *worker, const char *operation, const EXLPythonBuffer *error) {
    worker->failed = 1;
    fprintf(stderr, "BRIDGE_CALLBACK_PROBE worker=%d %s: %s\n", worker->index, operation,
            error && error->bytes ? error->bytes : "unexpected result");
}

static void expect(ProbeWorker *worker, const char *label, const char *source, const char *expected) {
    EXLPythonBuffer result = {0}, error = {0};
    int status = EXLPythonRunScript(worker->reference, source, strlen(source), &result, &error);
    if (status || !result.bytes || result.count != strlen(expected) ||
        memcmp(result.bytes, expected, result.count)) problem(worker, label, &error);
    EXLPythonBufferFree(&result);
    EXLPythonBufferFree(&error);
}

static const char checks[] =
    "import math\n"
    "import _exteraless_bridge as bridge\n"
    "from _exteraless_bridge import BridgeBackend\n"
    "from virtualjava.proxy import JavaInstance\n"
    "from virtualjava.backend import JavaMemberError\n"
    "bridge.xt_bind(JavaInstance, JavaMemberError)\n"
    "F = 'exteraless.probe.Native'\n"
    "def rejected(action, kind, message):\n"
    "    try: action()\n"
    "    except kind as error: assert message in str(error), str(error)\n"
    "    else: raise AssertionError('expected ' + kind.__name__)\n"
    "assert bridge.xt_service_ptr('java.call') == 0\n"
    "rejected(lambda: bridge.xt_call_host({}), JavaMemberError, 'not set')\n"
    "rejected(lambda: bridge.xt_set_owner_token('before-plugin'), RuntimeError, 'xt_set_plugin_id')\n"
    "rejected(lambda: bridge.xt_set_plugin_id(1), TypeError, 'str')\n"
    "rejected(lambda: bridge.xt_set_plugin_id(''), ValueError, 'nonempty')\n"
    "rejected(lambda: bridge.xt_set_plugin_id('a\\0b'), ValueError, 'NUL')\n"
    "bridge.xt_set_plugin_id(plugin_id)\n"
    "bridge.xt_set_plugin_id(plugin_id)\n"
    "rejected(lambda: bridge.xt_set_plugin_id('other'), RuntimeError, 'already bound')\n"
    "rejected(lambda: bridge.xt_call_host([]), TypeError, 'dict')\n"
    "backend = BridgeBackend(manifest_path='')\n"
    "sentinel = object()\n"
    "payload = [b'\\0\\xff', {'s': '\\u041f\\u0440\\u0438\\u0432\\u0435\\u0442\\0', 'f': float('-inf')}, sentinel]\n"
    "def check(reply, op):\n"
    "    assert reply['context'] == plugin_id and reply['interpreter'] > 0\n"
    "    request = reply['request']\n"
    "    assert request['op'] == op and request['fqcn'] == F and request['pluginId'] == plugin_id\n"
    "    return request\n"
    "instance = backend.construct(F, (42,))\n"
    "assert isinstance(instance, JavaInstance) and instance._backend is backend\n"
    "assert bridge.xt_register_handle(instance) == -7001\n"
    "assert backend.construct(F, (42,)) is instance\n"
    "for method, args in ((backend.call, (F, 'echo', payload, {'flag': True})),\n"
    "                     (backend.call_instance, (instance, 'echo', payload, {'flag': True}))):\n"
    "    request = check(method(*args), 'call' if args[0] == F else 'call_instance')\n"
    "    assert request['args'] == payload and request['args'][2] is sentinel\n"
    "    assert request['kwargs'] == {'flag': True}\n"
    "    if request['op'] == 'call_instance': assert request['instance'] == -7001\n"
    "assert check(backend.get(F, 'field'), 'get')['member'] == 'field'\n"
    "assert check(backend.get_instance(instance, 'field'), 'get_instance')['instance'] == -7001\n"
    "assert backend.set(F, 'blob', b'\\0\\xff') is None\n"
    "assert backend.set_instance(instance, 'blob', b'\\0\\xff') is None\n"
    "before = bridge.xt_handle_count()\n"
    "spoof = object()\n"
    "request = {'op': 'call', 'fqcn': F, 'member': 'echo', 'args': [float('nan'), b'x'], 'pluginId': spoof}\n"
    "echo = check(bridge.xt_call_host(request), 'call')\n"
    "assert echo['pluginId'] == plugin_id and request['pluginId'] is spoof\n"
    "assert math.isnan(echo['args'][0]) and echo['args'][1] == b'x'\n"
    "assert bridge.xt_handle_count() == before\n"
    "direct = bridge.xt_call_host({'op': 'get', 'fqcn': F, 'member': 'newHandle'})\n"
    "assert isinstance(direct, JavaInstance) and bridge.xt_register_handle(direct) == -7002\n"
    "assert check(direct.echo(9), 'call_instance')['instance'] == -7002\n"
    "handle = bridge.xt_register_handle(object())\n"
    "assert bridge.xt_call_host({'op':'call', 'fqcn':F, 'member':'release', 'args':[handle]}) is True\n"
    "assert bridge.xt_resolve_handle(handle) is None\n"
    "for member, message in [('denied','SecurityError'), ('badJSON','not JSON'),\n"
    "                        ('badEnvelope','boolean ok'), ('badTag','__bytes__'),\n"
    "                        ('dangling','dangling handle'), ('nulReply','not JSON'),\n"
    "                        ('rcFailure','rc=23'), ('pending','pending exception')]:\n"
    "    rejected(lambda: backend.call(F, member, (), {}), JavaMemberError, message)\n"
    "rejected(lambda: backend.set(F, 'denied', 1), JavaMemberError, 'native denied \\u03c0')\n"
    "rejected(lambda: backend.set_instance(instance, 'denied', 1), JavaMemberError, 'native denied')\n"
    "cycle = {}; cycle['self'] = cycle\n"
    "rejected(lambda: bridge.xt_call_host(cycle), RecursionError, 'recursion')\n"
    "assert check(backend.get(F, 'afterErrors'), 'get')['member'] == 'afterErrors'\n"
    "bridge.xt_register_service(plugin_id + '.get', bridge.xt_builtin_ptr('get'))\n"
    "try:\n"
    "    legacy = BridgeBackend(service=plugin_id, manifest_path='')\n"
    "    assert legacy.get(F, 'field') == 'field:' + F + '#field'\n"
    "finally: bridge.xt_unregister_service(plugin_id + '.get')\n";

/* Bounded local objects only. These calls all reach dispatch above, including
 * deliberate {ok:false} replies; no ctypes/Python service substitutes. */
static const char rollback_checks[] =
    "import weakref\n"
    "def native(member, args=(), **fields):\n"
    "    return bridge.xt_call_host(dict(op='call', fqcn=F, member=member, args=args, **fields))\n"
    "def fail(args): return native('rejectHandles', args)\n"
    "def keep(obj): return native('retainHandle', (obj,))\n"
    "def complete(handle): return native('completeProbeHandle', (handle,))\n"
    "def no_leak(action, kind=JavaMemberError, message='transaction rejected'):\n"
    "    count = bridge.xt_handle_count()\n"
    "    rejected(action, kind, message)\n"
    "    assert bridge.xt_handle_count() == count, 'failed native call leaked a handle'\n"
    "class Token: pass\n"
    "class Receiver:\n"
    "    _fqcn = F\n"
    "home = bridge.xt_set_interpreter_id(88000)\n"
    "assert bridge.xt_set_interpreter_id(home) == 88000\n"
    "original_count = bridge.xt_handle_count()\n"
    "old = Token(); old_id = bridge.xt_register_handle(old)\n"
    "pending = Token(); pending_id = keep(pending)\n"
    "callback = Token(); ref = weakref.ref(callback)\n"
    "no_leak(lambda: fail((callback,)))\n"
    "rejected_id = native('lastRejectedHandle')\n"
    "assert rejected_id > 0 and bridge.xt_resolve_handle(rejected_id) is None\n"
    "del callback\n"
    "assert ref() is None, 'failed callback kept its last reference'\n"
    "no_leak(lambda: fail((old, pending, instance, direct, Token())))\n"
    "assert bridge.xt_resolve_handle(old_id) is old\n"
    "assert bridge.xt_resolve_handle(pending_id) is pending\n"
    "assert bridge.xt_resolve_handle(-7001) is instance and bridge.xt_resolve_handle(-7002) is direct\n"
    "for _ in range(16): no_leak(lambda: fail((lambda: None,)))\n"
    "batch = [Token() for _ in range(320)]\n"
    "no_leak(lambda: fail(batch + batch[:32]))\n"
    "assert bridge.xt_resolve_handle(old_id) is old and bridge.xt_resolve_handle(pending_id) is pending\n"
    "for action in (lambda: backend.construct(F, (Token(),)),\n"
    "               lambda: backend.call(F, 'rejectHandles', (Token(),), {}),\n"
    "               lambda: backend.call_instance(instance, 'rejectHandles', (Token(),), {}),\n"
    "               lambda: backend.set(F, 'rejectHandles', Token()),\n"
    "               lambda: backend.set_instance(instance, 'rejectHandles', Token()),\n"
    "               lambda: backend.call_instance(Receiver(), 'rejectHandles', (), {}),\n"
    "               lambda: backend.set_instance(Receiver(), 'rejectHandles', Token()),\n"
    "               lambda: backend.get_instance(Receiver(), 'rejectHandles')):\n"
    "    no_leak(action)\n"
    "for member, message in [('denied','SecurityError'), ('badJSON','not JSON'),\n"
    "                        ('badTag','__bytes__'), ('rcFailure','rc=23'), ('pending','pending exception')]:\n"
    "    no_leak(lambda: native(member, (Token(),)), JavaMemberError, message)\n"
    "no_leak(lambda: bridge.xt_call_host({'op':'unknown', 'fqcn':F, 'args':[Token()]}), JavaMemberError, 'rc=-10')\n"
    "for action in (lambda: native('rejectHandles', (Token(), 1 << 100)),\n"
    "               lambda: backend.construct(F, (Token(), 1 << 100)),\n"
    "               lambda: backend.call_instance(Receiver(), 'rejectHandles', (Token(), 1 << 100), {}),\n"
    "               lambda: backend.set(F, 'rejectHandles', [Token(), 1 << 100]),\n"
    "               lambda: backend.set_instance(Receiver(), 'rejectHandles', [Token(), 1 << 100])):\n"
    "    no_leak(action, OverflowError, 'int64')\n"
    "boom = RuntimeError('original marshal exception')\n"
    "def broken_args():\n"
    "    yield Token()\n"
    "    raise boom\n"
    "count = bridge.xt_handle_count()\n"
    "try: backend.call(F, 'rejectHandles', broken_args(), {})\n"
    "except RuntimeError as error: assert error is boom\n"
    "else: raise AssertionError('marshal exception disappeared')\n"
    "assert bridge.xt_handle_count() == count\n"
    "class Reenter:\n"
    "    entered = False\n"
    "    def __init__(self, child=None, raw_id=None): self.child, self.raw_id = child, raw_id\n"
    "    @property\n"
    "    def _fqcn(self):\n"
    "        if not self.entered:\n"
    "            self.entered = True\n"
    "            target = self if self.child is None else self.child\n"
    "            if self.raw_id is not None: target = {'__handle__': self.raw_id, '__fqcn__': F}\n"
    "            self.accepted = keep(target)\n"
    "        return F\n"
    "child = Token(); parent = Reenter(child)\n"
    "count = bridge.xt_handle_count()\n"
    "rejected(lambda: fail((parent,)), JavaMemberError, 'transaction rejected')\n"
    "assert bridge.xt_handle_count() == count + 1\n"
    "assert bridge.xt_resolve_handle(parent.accepted) is child\n"
    "assert bridge.xt_resolve_handle(native('lastRejectedHandle')) is None\n"
    "assert complete(parent.accepted) == 1\n"
    "for raw in (False, True):\n"
    "    anchor = bridge.xt_register_handle(Token()); bridge.xt_release_handle(anchor)\n"
    "    parent = Reenter(raw_id=anchor + 1 if raw else None)\n"
    "    count = bridge.xt_handle_count()\n"
    "    rejected(lambda: fail((parent,)), JavaMemberError, 'transaction rejected')\n"
    "    assert parent.accepted == anchor + 1\n"
    "    assert bridge.xt_resolve_handle(parent.accepted) is parent\n"
    "    assert bridge.xt_handle_count() == count + 1\n"
    "    assert complete(parent.accepted) == 1\n"
    "class RejectReentrant:\n"
    "    entered = False\n"
    "    @property\n"
    "    def _fqcn(self):\n"
    "        if not self.entered:\n"
    "            self.entered = True\n"
    "            rejected(lambda: fail((self,)), JavaMemberError, 'transaction rejected')\n"
    "        return F\n"
    "no_leak(lambda: fail((RejectReentrant(),)))\n"
    "class ExplicitRetain:\n"
    "    @property\n"
    "    def _fqcn(self):\n"
    "        self.retained = bridge.xt_register_handle(self)\n"
    "        return F\n"
    "manual = ExplicitRetain()\n"
    "rejected(lambda: fail((manual,)), JavaMemberError, 'transaction rejected')\n"
    "assert bridge.xt_resolve_handle(manual.retained) is manual\n"
    "assert complete(manual.retained) == 1\n"
    "bridge.xt_register_service(plugin_id + '.set', bridge.xt_builtin_ptr('set'))\n"
    "try:\n"
    "    legacy = BridgeBackend(service=plugin_id, manifest_path='')\n"
    "    anchor = bridge.xt_register_handle(Token()); bridge.xt_release_handle(anchor)\n"
    "    class LegacyEscape:\n"
    "        @property\n"
    "        def _fqcn(self):\n"
    "            legacy.set(F, 'tag', {'__handle__': anchor + 1, '__fqcn__': F})\n"
    "            return F\n"
    "    manual = LegacyEscape()\n"
    "    rejected(lambda: fail((manual,)), JavaMemberError, 'transaction rejected')\n"
    "    assert bridge.xt_resolve_handle(anchor + 1) is manual\n"
    "    assert complete(anchor + 1) == 1\n"
    "finally: bridge.xt_unregister_service(plugin_id + '.set')\n"
    "during_cleanup = []; survivor = Token()\n"
    "class ReenterOnDelete:\n"
    "    def __del__(self): during_cleanup.append(keep(survivor))\n"
    "def ephemeral_args():\n"
    "    yield ReenterOnDelete()\n"
    "    raise boom\n"
    "count = bridge.xt_handle_count()\n"
    "try: backend.call(F, 'rejectHandles', ephemeral_args(), {})\n"
    "except RuntimeError as error: assert error is boom\n"
    "else: raise AssertionError('cleanup replaced the marshal exception')\n"
    "assert len(during_cleanup) == 1 and bridge.xt_handle_count() == count + 1\n"
    "assert bridge.xt_resolve_handle(during_cleanup[0]) is survivor\n"
    "assert complete(during_cleanup[0]) == 1\n"
    "def realm_switch_args():\n"
    "    yield Token()\n"
    "    bridge.xt_set_interpreter_id(88000)\n"
    "def clear_args():\n"
    "    yield Token()\n"
    "    bridge.xt_clear_handles()\n"
    "no_leak(lambda: backend.call(F, 'rejectHandles', realm_switch_args(), {}), RuntimeError, 'handle realm')\n"
    "no_leak(lambda: backend.call(F, 'rejectHandles', clear_args(), {}), RuntimeError, 'clear handles')\n"
    "assert bridge.xt_set_interpreter_id(home) == home\n"
    "assert bridge.xt_set_interpreter_id(88000) == home\n"
    "assert bridge.xt_handle_count() == 0\n"
    "no_leak(lambda: fail((Token(),)))\n"
    "assert bridge.xt_set_interpreter_id(home) == 88000\n"
    "assert bridge.xt_resolve_handle(old_id) is old and bridge.xt_resolve_handle(pending_id) is pending\n"
    "no_leak(lambda: fail((Token(),)))\n"
    "late_failed = native('lastRejectedHandle'); future = Token(); future_id = keep(future)\n"
    "assert future_id > late_failed\n"
    "assert complete(late_failed) == 0 and bridge.xt_resolve_handle(future_id) is future\n"
    "assert complete(pending_id) == 1 and complete(pending_id) == 0\n"
    "assert bridge.xt_resolve_handle(future_id) is future and bridge.xt_resolve_handle(old_id) is old\n"
    "assert complete(future_id) == 1 and bridge.xt_release_handle(old_id) is True\n"
    "assert bridge.xt_handle_count() == original_count\n"
    "assert bridge.xt_resolve_handle(-7001) is instance and bridge.xt_resolve_handle(-7002) is direct\n";

static const char owner_unbound_checks[] =
    "assert len(owner_token.encode('utf-8')) == 256\n"
    "for token in (None, 1, b'bytes'):\n"
    "    rejected(lambda: bridge.xt_set_owner_token(token), TypeError, 'str')\n"
    "for token in ('', '\\0', 'a\\0b', 'x' * 257, '\\u03c0' * 129, '\\U0001f600' * 65):\n"
    "    rejected(lambda: bridge.xt_set_owner_token(token), ValueError, '256')\n"
    "rejected(lambda: bridge.xt_set_owner_token('bad\\ud800'), UnicodeEncodeError, 'utf-8')\n"
    "ignored_owner_visits = []\n"
    "class IgnoredOwner:\n"
    "    @property\n"
    "    def _fqcn(self):\n"
    "        ignored_owner_visits.append(True)\n"
    "        return F\n"
    "ignored_owner = IgnoredOwner()\n"
    "class ContextKey(str):\n"
    "    def __hash__(self): return 0\n"
    "    def __eq__(self, other): raise AssertionError('context key equality hook')\n"
    "    def __str__(self): raise AssertionError('context key str hook')\n"
    "class OwnerKeyAlias:\n"
    "    def __str__(self): return 'ownerToken'\n"
    "def owner_echo(fields):\n"
    "    request = dict(op='get', fqcn=F, member='ownerProbe')\n"
    "    request.update(fields)\n"
    "    count = bridge.xt_handle_count()\n"
    "    result = check(bridge.xt_call_host(request), 'get')\n"
    "    assert bridge.xt_handle_count() == count and ignored_owner_visits == []\n"
    "    if 'ownerToken' in fields: assert request['ownerToken'] is fields['ownerToken']\n"
    "    return result\n"
    "for fields in ({'ownerToken':'forged', 'pluginId':'wrong'}, {'ownerToken':ignored_owner},\n"
    "               {ContextKey('ownerToken'):ignored_owner}, {OwnerKeyAlias():ignored_owner}):\n"
    "    assert 'ownerToken' not in owner_echo(fields), 'unbound token was forwarded'\n"
    "assert 'ownerToken' not in check(backend.call(F, 'ownerProbe', (), {}), 'call')\n";

static const char owner_bound_checks[] =
    "class TokenString(str):\n"
    "    def __eq__(self, other): raise AssertionError('token equality hook')\n"
    "    def __ne__(self, other): raise AssertionError('token inequality hook')\n"
    "    def __str__(self): raise AssertionError('token str hook')\n"
    "    def __len__(self): raise AssertionError('token length hook')\n"
    "    def encode(self, *args, **kwargs): raise AssertionError('token encode hook')\n"
    "source_token = TokenString(owner_token); token_ref = weakref.ref(source_token)\n"
    "assert bridge.xt_set_owner_token(source_token) is None\n"
    "del source_token\n"
    "assert token_ref() is None, 'C state retained a str subclass rather than plain str'\n"
    "assert bridge.xt_set_owner_token(owner_token) is None\n"
    "assert bridge.xt_set_owner_token(TokenString(owner_token)) is None\n"
    "class LyingToken(str):\n"
    "    def __eq__(self, other): return True\n"
    "    def __ne__(self, other): return False\n"
    "    def __str__(self): return owner_token\n"
    "for different in ('another-generation', LyingToken('forged'), TokenString('different')):\n"
    "    rejected(lambda: bridge.xt_set_owner_token(different), RuntimeError, 'already bound')\n"
    "rejected(lambda: bridge.xt_set_owner_token('x' * 257), ValueError, '256')\n"
    "rejected(lambda: bridge.xt_set_owner_token('bad\\udfff'), UnicodeEncodeError, 'utf-8')\n"
    "assert bridge.xt_set_owner_token(owner_token) is None\n"
    "class CollidingContextKey(str):\n"
    "    def __hash__(self): return hash('ownerToken')\n"
    "    def __eq__(self, other): return True\n"
    "for fields in ({'ownerToken':'forged', 'pluginId':'wrong'}, {'ownerToken':None},\n"
    "               {'ownerToken':ignored_owner}, {ContextKey('ownerToken'):ignored_owner},\n"
    "               {OwnerKeyAlias():ignored_owner},\n"
    "               {ContextKey('pluginId'):ignored_owner, 'ownerToken':'forged'},\n"
    "               {'ownerToken':'forged', ContextKey('ownerToken'):'duplicate'},\n"
    "               {CollidingContextKey('shadow'):'harmless'}):\n"
    "    assert owner_echo(fields)['ownerToken'] == owner_token\n"
    "assert backend.construct(F, (42,)) is instance\n"
    "assert check(backend.call(F, 'ownerProbe', (), {}), 'call')['ownerToken'] == owner_token\n"
    "assert check(backend.call_instance(instance, 'ownerProbe', (), {}), 'call_instance')['ownerToken'] == owner_token\n"
    "assert check(backend.get(F, 'ownerProbe'), 'get')['ownerToken'] == owner_token\n"
    "assert check(backend.get_instance(instance, 'ownerProbe'), 'get_instance')['ownerToken'] == owner_token\n"
    "assert backend.set(F, 'ownerProbe', b'\\0\\xff') is None\n"
    "assert backend.set_instance(instance, 'ownerProbe', b'\\0\\xff') is None\n"
    "previous_realm = bridge.xt_set_interpreter_id(88001)\n"
    "try:\n"
    "    assert bridge.xt_set_owner_token(owner_token) is None\n"
    "    assert owner_echo({'ownerToken':'wrong-realm'})['ownerToken'] == owner_token\n"
    "finally: bridge.xt_set_interpreter_id(previous_realm)\n";

static const char bulk_clear_checks[] =
    "import gc\n"
    "bulk_home = bridge.xt_set_interpreter_id(91000)\n"
    "class Survivor: pass\n"
    "def release_birth(birth):\n"
    "    ref, handle = birth\n"
    "    assert ref() is not None and bridge.xt_handle_count() == 1\n"
    "    assert bridge.xt_resolve_handle(handle) is ref()\n"
    "    assert bridge.xt_release_handle(handle) is True\n"
    "    assert ref() is None\n"
    "try:\n"
    "    births = []; finalized = []\n"
    "    class Retained:\n"
    "        def __del__(self):\n"
    "            finalized.append('parent')\n"
    "            value = Survivor()\n"
    "            births.append((weakref.ref(value), bridge.xt_register_handle(value)))\n"
    "    value = Retained(); old_ref = weakref.ref(value)\n"
    "    old_id = bridge.xt_register_handle(value); del value\n"
    "    bridge.xt_clear_handles(); gc.collect()\n"
    "    assert old_ref() is None and finalized == ['parent'] and len(births) == 1\n"
    "    assert births[0][1] > old_id\n"
    "    release_birth(births[0])\n"
    "    assert bridge.xt_release_handle(old_id) is False\n"
    "    # Recursive clear consumes a fresh table, never the parent's snapshot.\n"
    "    nested = []; nested_ids = []; births = []\n"
    "    class NestedChild:\n"
    "        def __del__(self):\n"
    "            nested.append('child')\n"
    "            value = Survivor()\n"
    "            births.append((weakref.ref(value), bridge.xt_register_handle(value)))\n"
    "    class NestedParent:\n"
    "        def __del__(self):\n"
    "            nested.append('parent')\n"
    "            nested_ids.append(bridge.xt_register_handle(NestedChild()))\n"
    "            bridge.xt_clear_handles()\n"
    "    previous = bridge.xt_register_handle(NestedParent())\n"
    "    bridge.xt_clear_handles()\n"
    "    assert nested == ['parent', 'child'] and len(births) == 1\n"
    "    assert previous < nested_ids[0] < births[0][1]\n"
    "    release_birth(births[0]); bridge.xt_clear_handles()\n"
    "    assert nested == ['parent', 'child']\n"
    "    # Explicit self-retention creates a new identity and finalizes only once.\n"
    "    resurrected = []; self_finalizers = []\n"
    "    class SelfRetained:\n"
    "        def __del__(self):\n"
    "            self_finalizers.append(True)\n"
    "            resurrected.append((weakref.ref(self), bridge.xt_register_handle(self)))\n"
    "    previous = bridge.xt_register_handle(SelfRetained())\n"
    "    bridge.xt_clear_handles()\n"
    "    assert resurrected[0][1] > previous and self_finalizers == [True]\n"
    "    release_birth(resurrected[0])\n"
    "    assert self_finalizers == [True]\n"
    "    # Registration through real native marshal/dispatch is also retained.\n"
    "    births = []\n"
    "    class NativeRetained:\n"
    "        def __del__(self):\n"
    "            value = Survivor()\n"
    "            births.append((weakref.ref(value), keep(value)))\n"
    "    bridge.xt_register_handle(NativeRetained()); bridge.xt_clear_handles()\n"
    "    assert len(births) == 1\n"
    "    release_birth(births[0])\n"
    "    # Reentrant growth must affect only the fresh table.\n"
    "    births = []; finalizer_ids = []\n"
    "    class ManyRetained:\n"
    "        def __init__(self, ordinal): self.ordinal = ordinal\n"
    "        def __del__(self):\n"
    "            finalizer_ids.append(self.ordinal)\n"
    "            value = Survivor()\n"
    "            births.append((weakref.ref(value), bridge.xt_register_handle(value)))\n"
    "    previous_ids = [bridge.xt_register_handle(ManyRetained(i)) for i in range(320)]\n"
    "    bridge.xt_clear_handles()\n"
    "    assert sorted(finalizer_ids) == list(range(320)) and bridge.xt_handle_count() == 320\n"
    "    assert len({handle for ref, handle in births}) == 320\n"
    "    for ref, handle in births:\n"
    "        assert handle > max(previous_ids) and ref() is not None\n"
    "        assert bridge.xt_resolve_handle(handle) is ref()\n"
    "        assert bridge.xt_release_handle(handle) is True and ref() is None\n"
    "    assert bridge.xt_handle_count() == 0\n"
    "    # A finalizer can switch realms and register a C service without locks\n"
    "    # crossing DECREF. The original clear must not reset that other realm.\n"
    "    bridge.xt_set_interpreter_id(91002)\n"
    "    births = []; swapped = []; service_name = plugin_id + '.bulk.get'\n"
    "    service_address = bridge.xt_builtin_ptr('get')\n"
    "    class RealmRetained:\n"
    "        def __del__(self):\n"
    "            swapped.append(bridge.xt_set_interpreter_id(91003))\n"
    "            value = Survivor()\n"
    "            births.append((weakref.ref(value), bridge.xt_register_handle(value)))\n"
    "            bridge.xt_register_service(service_name, service_address)\n"
    "    original_id = bridge.xt_register_handle(RealmRetained())\n"
    "    bridge.xt_clear_handles()\n"
    "    assert swapped == [91002] and bridge.xt_handle_count() == 1\n"
    "    assert bridge.xt_service_ptr(service_name) == service_address\n"
    "    assert bridge.xt_set_interpreter_id(91002) == 91003 and bridge.xt_handle_count() == 0\n"
    "    assert bridge.xt_release_handle(original_id) is False\n"
    "    assert bridge.xt_set_interpreter_id(91003) == 91002\n"
    "    release_birth(births[0])\n"
    "    assert bridge.xt_unregister_service(service_name) is True\n"
    "finally:\n"
    "    bridge.xt_set_interpreter_id(bulk_home)\n"
    "assert bridge.xt_resolve_handle(-7001) is instance and bridge.xt_resolve_handle(-7002) is direct\n"
    "assert owner_echo({})['ownerToken'] == owner_token\n";

static const char terminal_setup[] =
    "def arm_terminal_probe(force):\n"
    "    entries = [\n"
    "        (bridge.xt_set_plugin_id, (plugin_id,)),\n"
    "        (bridge.xt_set_owner_token, (owner_token,)),\n"
    "        (bridge.xt_call_host, ({'op':'get','fqcn':F,'member':'ownerProbe'},)),\n"
    "        (bridge.xt_register_service, (plugin_id + '.terminal', bridge.xt_builtin_ptr('get'))),\n"
    "        (bridge.xt_unregister_service, (plugin_id + '.terminal',)),\n"
    "        (bridge.xt_service_ptr, (plugin_id + '.terminal',)),\n"
    "        (bridge.xt_install_mock_service, (plugin_id + '.terminal',)),\n"
    "        (bridge.xt_builtin_ptr, ('get',)),\n"
    "        (bridge.xt_mock_log, ()), (bridge.xt_mock_log_clear, ()),\n"
    "        (bridge.xt_register_handle, (Survivor(),)),\n"
    "        (bridge.xt_resolve_handle, (0,)), (bridge.xt_release_handle, (0,)),\n"
    "        (bridge.xt_handle_count, ()), (bridge.xt_clear_handles, ()),\n"
    "        (bridge.xt_set_interpreter_id, (99881,)),\n"
    "        (bridge.xt_bind, (JavaInstance, JavaMemberError)),\n"
    "        (backend.construct, (F, ())), (backend.call, (F, 'unused', (), {})),\n"
    "        (backend.call_instance, (instance, 'unused', (), {})),\n"
    "        (backend.get, (F, 'unused')), (backend.get_instance, (instance, 'unused')),\n"
    "        (backend.set, (F, 'unused', None)), (backend.set_instance, (instance, 'unused', None)),\n"
    "        (backend.member_kind, (F, 'unused')), (backend.class_exists, (F,)),\n"
    "        (bridge.BridgeBackend, ()),\n"
    "    ]\n"
    "    assert len(entries) == 27\n"
    "    class TerminalRetained:\n"
    "        def __del__(self):\n"
    "            self.note(27, 1)\n"
    "            for index, (function, args) in self.enumerate(self.entries):\n"
    "                try: function(*args)\n"
    "                except self.runtime_error as error:\n"
    "                    text = self.text(error)\n"
    "                    self.note(index, 1 if 'closed' in text or 'cleared' in text else 0)\n"
    "                except self.base_error: self.note(index, 0)\n"
    "                else: self.note(index, 0)\n"
    "            payload = self.make_payload()\n"
    "            try: self.register(payload)\n"
    "            except self.dead_errors: self.note(28, 1)\n"
    "            except self.base_error: self.note(29, 1)\n"
    "            else: self.note(28, 0)\n"
    "            del payload\n"
    "    value = TerminalRetained()\n"
    "    value.entries = entries if force else ()\n"
    "    value.note, value.make_payload = _probe_terminal_note, _probe_terminal_payload\n"
    "    value.register = bridge.xt_register_handle\n"
    "    value.enumerate, value.text = enumerate, str\n"
    "    value.runtime_error, value.base_error = RuntimeError, BaseException\n"
    "    value.dead_errors = (RuntimeError, AttributeError)\n"
    "    bridge.xt_register_handle(value)\n"
    "    del value\n"
    "    if force: _probe_terminal_clear()\n";

/* The engine leaves its saved main state detached. Borrow a NEW temporary main
 * state exactly as the embedding does when creating workers; never migrate the
 * engine's saved state and never use PyGILState_Ensure. The parent uses child
 * 1's pluginId: a pluginId-keyed token registry must not pass this isolation
 * check. Children neither inherit nor overwrite its already-bound C epoch. */
static int check_parent_owner(int bind) {
    PyThreadState *temporary = PyThreadState_New(PyInterpreterState_Main());
    if (!temporary) return -1;
    PyEval_RestoreThread(temporary);
    PyObject *bridge = PyImport_ImportModule("_exteraless_bridge");
    PyObject *result = NULL;
    int status = -1;
    if (!bridge) goto done;
    if (bind) {
        result = PyObject_CallMethod(bridge, "xt_set_plugin_id", "s", plugin_ids[0]);
        if (!result) goto done;
        Py_CLEAR(result);
    }
    result = PyObject_CallMethod(bridge, "xt_set_owner_token", "s", parent_owner_token);
    if (result != Py_None) goto done;
    Py_CLEAR(result);
    result = PyObject_CallMethod(bridge, "xt_set_owner_token", "s", owner_prefixes[0]);
    if (result || !PyErr_ExceptionMatches(PyExc_RuntimeError)) goto done;
    PyErr_Clear();
    status = 0;
done:
    if (status != 0 && PyErr_Occurred()) PyErr_Print();
    Py_XDECREF(result);
    Py_XDECREF(bridge);
    PyThreadState_Clear(temporary);
    PyThreadState_DeleteCurrent();
    return status;
}

static void worker_main(void *opaque) {
    ProbeWorker *worker = opaque;
    EXLPythonInterpreterConfiguration config = {.check_multi_interp_extensions = 1, .own_gil = 1};
    EXLPythonBuffer error = {0};
    worker->owner = PyThread_get_thread_ident();
    if (EXLPythonCreateInterpreter(&config, &worker->reference, &error) != 0)
        problem(worker, "create", &error);
    else {
        /* Hex avoids interpolating a host path as executable Python source. */
        size_t n = strlen(worker->context->python_root);
        char *setup = malloc(n * 2 + 512);
        if (!setup) problem(worker, "allocate bootstrap", NULL);
        else {
            char *p = setup;
            p += sprintf(p, "import sys\nsys.path.insert(0, bytes.fromhex('");
            for (size_t i = 0; i < n; i++) p += sprintf(p, "%02x", (unsigned char)worker->context->python_root[i]);
            sprintf(p, "').decode('utf-8'))\nplugin_id = 'bridge-probe-%d-\\u03c0'\n"
                    "owner_token = '%s' + '\\u03c0' * 110\n", worker->index, owner_prefixes[worker->index - 1]);
            expect(worker, "bootstrap", setup, "None");
            free(setup);
            if (!worker->failed) expect(worker, "native dispatch checks", checks, "None");
            if (!worker->failed) {
                expect(worker, "native handle rollback checks", rollback_checks, "None");
                worker->rollback_checked = !worker->failed;
                worker->baseline_calls = worker->calls;
            }
            if (!worker->failed) expect(worker, "unbound owner token checks", owner_unbound_checks, "None");
            if (!worker->failed) {
                worker->owner_bound = 1;
                expect(worker, "C-owned epoch checks", owner_bound_checks, "None");
                worker->owner_checked = !worker->failed;
            }
            if (!worker->failed) {
                unsigned int before_bulk = worker->calls;
                expect(worker, "install bulk-clear test helpers", "native('armClearProbe')", "None");
                expect(worker, "reentrant bulk-clear checks", bulk_clear_checks, "None");
                expect(worker, "terminal probe definitions", terminal_setup, "None");
                worker->bulk_checked = !worker->failed;
                worker->bulk_calls = worker->calls - before_bulk;
            }
        }
        if (xt_host_release_handle(-7001) != -2) problem(worker, "detached worker release", NULL);
    }
    EXLPythonBufferFree(&error);
    PyThread_release_lock(worker->ready);
    PyThread_acquire_lock(worker->proceed, WAIT_LOCK);
    PyThread_release_lock(worker->proceed);
    if (worker->reference) {
        if (!worker->failed) {
            expect(worker, "isolated handle after peer calls", "bridge.xt_resolve_handle(-7001) is instance", "True");
            expect(worker, "isolated token after peer calls", "owner_echo({'ownerToken':'peer-spoof'})['ownerToken'] == owner_token", "True");
            if (worker->index == 1) {
                expect(worker, "uninstall inside active callback",
                       "bridge.xt_call_host({'op':'get','fqcn':F,'member':'detach'})", "drained");
                expect(worker, "post-uninstall error",
                       "rejected(lambda: bridge.xt_call_host({'op':'get'}), JavaMemberError, 'no native dispatcher')", "None");
                expect(worker, "post-uninstall marshal rollback",
                       "no_leak(lambda: bridge.xt_call_host({'op':'get','args':[Token()]}), JavaMemberError, 'no native dispatcher')", "None");
            }
            if (!worker->failed)
                expect(worker, "arm terminal ownership check", worker->index == 1
                    ? "arm_terminal_probe(True)" : "arm_terminal_probe(False)", "None");
        }
        if (EXLPythonDestroyInterpreter(worker->reference, &error) != 0) problem(worker, "destroy", &error);
        EXLPythonBufferFree(&error);
        /* Native-only assertions after Py_EndInterpreter: never call the dead
         * interpreter to inspect its weakrefs, module state or handle table. */
        if (!worker->failed && (worker->terminal_finalizers != 1 || worker->terminal_attempts != 1 ||
            worker->terminal_created != 1 || worker->terminal_freed != 1 || worker->terminal_faults ||
            (worker->index == 1 && (worker->terminal_mask != TERMINAL_API_MASK ||
                                   worker->terminal_rejected != 1 || worker->terminal_admitted != 0))))
        {
            fprintf(stderr, "TERMINAL_COUNTERS worker=%d finalizers=%u attempts=%u created=%u freed=%u "
                    "rejected=%u admitted=%u faults=%u mask=%u\n", worker->index,
                    worker->terminal_finalizers, worker->terminal_attempts, worker->terminal_created,
                    worker->terminal_freed, worker->terminal_rejected, worker->terminal_admitted,
                    worker->terminal_faults, worker->terminal_mask);
            problem(worker, "terminal ownership counters", NULL);
        }
    }
    PyThread_release_lock(worker->done);
}

int EXLRunBridgeCallbackProbe(const char *home, const char *stdlib_path,
                               const char *dynload_path, const char *executable_path,
                               const char *python_root, const char *report_path) {
    if (!python_root || strlen(python_root) > 32767 || !report_path) return 1;
    FILE *report = fopen(report_path, "w");
    if (!report) return 1;
    fputs("{\"ok\":false,\"phase\":\"native-bridge-initializing\"}\n", report);
    fclose(report);
    ProbeContext context = {.python_root = python_root};
    /* Registration and C-owned copying must work before Python starts. */
    EXLPythonBridgeBuffer copy = {0};
    char input[] = "a\0b";
    if (EXLPythonBridgeBufferCopy(&copy, input, 3) != 0) return 2;
    input[0] = 'z';
    int failed = copy.count != 3 || memcmp(copy.bytes, "a\0b", 3);
    EXLPythonBridgeBufferFree(&copy);
    if (failed || EXLPythonBridgeInstallDispatcher(dispatch, &context, release_context) != 0) return 2;
    if (EXLPythonBridgeInstallDispatcher(dispatch, &context, release_context) != -2 || context.released) return 2;
    if (EXLPythonBridgeUninstallDispatcher(dispatch, NULL) != -1) return 2;
    const char *paths[] = {stdlib_path, dynload_path};
    EXLPythonProcessConfiguration config = {
        .program_name = "exteraless-bridge-callback-probe", .home = home, .executable = executable_path,
        .module_search_paths = stdlib_path && dynload_path ? paths : NULL,
        .module_search_path_count = stdlib_path && dynload_path ? 2 : 0,
    };
    EXLPythonBuffer error = {0};
    if (EXLPythonInitialize(&config, &error) != 0) {
        fprintf(stderr, "BRIDGE_CALLBACK_PROBE initialize: %s\n", error.bytes ? error.bytes : "failed");
        EXLPythonBufferFree(&error);
        EXLPythonBridgeUninstallDispatcher(dispatch, &context);
        return 3;
    }
    if (check_parent_owner(1) != 0) {
        EXLPythonFinalize(&error);
        EXLPythonBufferFree(&error);
        EXLPythonBridgeUninstallDispatcher(dispatch, &context);
        return 3;
    }
    for (int i = 0; i < 2; i++) {
        ProbeWorker *worker = &context.workers[i];
        worker->index = i + 1;
        worker->context = &context;
        memcpy(worker->owner_token, owner_prefixes[i], 36);
        for (size_t offset = 36; offset < PROBE_OWNER_TOKEN_BYTES; offset += 2) {
            worker->owner_token[offset] = (char)0xcf;
            worker->owner_token[offset + 1] = (char)0x80;
        }
        worker->owner_token[PROBE_OWNER_TOKEN_BYTES] = 0;
        worker->ready = PyThread_allocate_lock();
        worker->proceed = PyThread_allocate_lock();
        worker->done = PyThread_allocate_lock();
        if (!worker->ready || !worker->proceed || !worker->done) { failed = 1; break; }
        PyThread_acquire_lock(worker->ready, WAIT_LOCK);
        PyThread_acquire_lock(worker->proceed, WAIT_LOCK);
        PyThread_acquire_lock(worker->done, WAIT_LOCK);
        worker->started = PyThread_start_new_thread(worker_main, worker) != PYTHREAD_INVALID_THREAD_ID;
        if (!worker->started) { failed = 1; break; }
    }
    for (int i = 0; i < 2; i++) {
        if (context.workers[i].started) PyThread_acquire_lock(context.workers[i].ready, WAIT_LOCK);
    }
    if (xt_host_release_handle(-7001) != -2) failed = 1;
    if (!context.workers[0].python_id || context.workers[0].python_id == context.workers[1].python_id) failed = 1;
    if (!memcmp(context.workers[0].owner_token, context.workers[1].owner_token, PROBE_OWNER_TOKEN_BYTES) ||
        check_parent_owner(0) != 0) failed = 1;
    /* Worker 1 owns the original detach-in-callback check. Complete worker 2's
     * final native owner check first, while worker 1 remains parked and bound;
     * otherwise its RPC can race the process-wide dispatcher uninstall. */
    for (int i = 1; i >= 0; i--) {
        ProbeWorker *worker = &context.workers[i];
        if (worker->started) {
            PyThread_release_lock(worker->proceed);
            PyThread_acquire_lock(worker->done, WAIT_LOCK);
            failed |= worker->failed || worker->operations != 127 || !worker->rollback_checked ||
                      !worker->owner_checked || !worker->bulk_checked ||
                      worker->bound_operations != 127 || !worker->unbound_calls;
            PyThread_release_lock(worker->ready);
            PyThread_release_lock(worker->done);
        }
        if (worker->ready) PyThread_free_lock(worker->ready);
        if (worker->proceed) PyThread_free_lock(worker->proceed);
        if (worker->done) PyThread_free_lock(worker->done);
    }
    if (EXLPythonBridgeUninstallDispatcher(dispatch, &context) == 0) failed = 1; /* Expected active-call detach. */
    if (context.released != 1) failed = 1;
    if (EXLPythonFinalize(&error) != 0) {
        fprintf(stderr, "BRIDGE_CALLBACK_PROBE finalize: %s\n", error.bytes ? error.bytes : "failed");
        failed = 1;
    }
    EXLPythonBufferFree(&error);
    if (failed) return 4;
    report = fopen(report_path, "w");
    if (!report) return 5;
    fprintf(report, "{\"ok\":true,\"probe\":\"native-bridge-callback\",\"python\":\"%s\",\"platform\":\"%s\","
          "\"own_gil_interpreters\":2,\"native_workers\":2,\"native_dispatcher\":true,"
          "\"seven_backend_operations\":true,\"plugin_context_isolated\":true,"
          "\"spoofed_plugin_id_ignored\":true,\"byte_and_float_tags\":true,\"negative_handles\":true,"
          "\"owner_release\":true,\"detached_release_rejected\":true,\"dispatcher_lifetime\":true,"
          "\"error_envelopes\":true,\"counted_buffers\":true,\"legacy_service_override\":true,"
          "\"native_handle_rollback\":true,\"reentrant_handle_publication\":true,"
          "\"rollback_preserves_existing_and_negative\":true,\"late_completion_identity\":true,"
          "\"rollback_exception_identity\":true,\"native_realm_guard\":true,"
          "\"owner_token_authoritative\":true,\"unbound_owner_token_removed\":true,"
          "\"immutable_owner_token\":true,\"canonical_owner_token\":true,\"owner_token_validation\":true,"
          "\"isolated_owner_tokens\":true,\"parent_owner_isolated\":true,\"owner_bound_seven_ops\":true,"
          "\"bulk_clear_reentrant_registration\":true,\"bulk_clear_nested_once\":true,"
          "\"bulk_clear_realm_registry_swaps\":true,\"bulk_clear_monotonic_ids\":true,"
          "\"terminal_admission_checks\":27,\"terminal_owned_refs_released\":true,"
          "\"terminal_payloads_created\":%u,\"terminal_payloads_freed\":%u,"
          "\"terminal_admission_rejected\":%u,\"terminal_admission_before_clear\":%u,"
          "\"previous_suite_callbacks\":%u,\"bulk_clear_callbacks\":%u,"
          "\"baseline_callbacks\":%u,\"owner_bound_callbacks\":%u,\"callbacks\":%u,\"finalized\":true}\n",
          PY_VERSION, Py_GetPlatform(), context.workers[0].terminal_created + context.workers[1].terminal_created,
          context.workers[0].terminal_freed + context.workers[1].terminal_freed,
          context.workers[0].terminal_rejected + context.workers[1].terminal_rejected,
          context.workers[0].terminal_admitted + context.workers[1].terminal_admitted,
          context.workers[0].calls + context.workers[1].calls - context.workers[0].bulk_calls - context.workers[1].bulk_calls,
          context.workers[0].bulk_calls + context.workers[1].bulk_calls,
          context.workers[0].baseline_calls + context.workers[1].baseline_calls,
          context.workers[0].bound_calls + context.workers[1].bound_calls,
          context.workers[0].calls + context.workers[1].calls);
    fclose(report);
    puts("EXTERALESS_BRIDGE_CALLBACK_PROBE_OK");
    return 0;
}

#ifdef EXL_BRIDGE_CALLBACK_PROBE_MAIN
int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        fputs("usage: bridge-callback-probe report.json python-root [python-home]\n", stderr);
        return 2;
    }
    return EXLRunBridgeCallbackProbe(argc == 4 ? argv[3] : NULL, NULL, NULL, NULL, argv[2], argv[1]);
}
#endif
