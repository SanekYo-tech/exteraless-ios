#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "EXLPythonBridge.h"
#include "EXLPythonEngine.h"
#include "bridge_callback_probe.h"

typedef struct ProbeContext ProbeContext;
typedef struct {
    ProbeContext *context;
    int index, failed, started, rollback_checked;
    unsigned long owner;
    int64_t reference, python_id;
    int64_t last_rejected_handle;
    unsigned int operations, calls;
    PyThread_type_lock ready, proceed, done;
} ProbeWorker;

struct ProbeContext {
    const char *python_root;
    ProbeWorker workers[2];
    /* Written by the last callback (or uninstall), read after worker join. */
    int released;
};

static const char *const plugin_ids[] = {"bridge-probe-1-\xcf\x80", "bridge-probe-2-\xcf\x80"};
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
    int operation = -1;
    for (int i = 0; i < 7; i++) {
        if (PyUnicode_CompareWithASCIIString(op, operations[i]) == 0) operation = i;
    }
    if (operation < 0) goto done;
    worker->operations |= 1u << operation;
    const char *method = member && PyUnicode_Check(member) ? PyUnicode_AsUTF8(member) : "";
    if (!method) goto done;
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
        char *setup = malloc(n * 2 + 256);
        if (!setup) problem(worker, "allocate bootstrap", NULL);
        else {
            char *p = setup;
            p += sprintf(p, "import sys\nsys.path.insert(0, bytes.fromhex('");
            for (size_t i = 0; i < n; i++) p += sprintf(p, "%02x", (unsigned char)worker->context->python_root[i]);
            sprintf(p, "').decode('utf-8'))\nplugin_id = 'bridge-probe-%d-\\u03c0'\n", worker->index);
            expect(worker, "bootstrap", setup, "None");
            free(setup);
            if (!worker->failed) expect(worker, "native dispatch checks", checks, "None");
            if (!worker->failed) {
                expect(worker, "native handle rollback checks", rollback_checks, "None");
                worker->rollback_checked = !worker->failed;
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
            if (worker->index == 1) {
                expect(worker, "uninstall inside active callback",
                       "bridge.xt_call_host({'op':'get','fqcn':F,'member':'detach'})", "drained");
                expect(worker, "post-uninstall error",
                       "rejected(lambda: bridge.xt_call_host({'op':'get'}), JavaMemberError, 'no native dispatcher')", "None");
                expect(worker, "post-uninstall marshal rollback",
                       "no_leak(lambda: bridge.xt_call_host({'op':'get','args':[Token()]}), JavaMemberError, 'no native dispatcher')", "None");
            }
        }
        if (EXLPythonDestroyInterpreter(worker->reference, &error) != 0) problem(worker, "destroy", &error);
        EXLPythonBufferFree(&error);
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
    for (int i = 0; i < 2; i++) {
        ProbeWorker *worker = &context.workers[i];
        worker->index = i + 1;
        worker->context = &context;
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
    for (int i = 0; i < 2; i++) {
        if (context.workers[i].started) PyThread_release_lock(context.workers[i].proceed);
    }
    for (int i = 0; i < 2; i++) {
        ProbeWorker *worker = &context.workers[i];
        if (worker->started) {
            PyThread_acquire_lock(worker->done, WAIT_LOCK);
            failed |= worker->failed || worker->operations != 127 || !worker->rollback_checked;
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
          "\"callbacks\":%u,\"finalized\":true}\n", PY_VERSION, Py_GetPlatform(),
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
