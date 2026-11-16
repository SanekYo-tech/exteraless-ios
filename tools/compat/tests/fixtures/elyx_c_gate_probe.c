/* Test-only native recorder, pending-PyErr/terminal helpers and response-free
 * accounting. The shipping bridge is included byte-for-byte. Only its free()
 * calls are observed; allocation, ABI, module state and dispatch stay real.
 * No source descriptor, archive, fd registry or Python callback is implemented. */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static void observed_bridge_free(void *pointer);
#define free observed_bridge_free
#include "../../../../python/bridge/_exteraless_bridge.c"
#undef free

typedef struct {
    unsigned long calls, active, peak_active, gil_faults;
    unsigned long contexts, released, released_active, retained_checks;
    unsigned long buffers, freed, outstanding, legacy_calls;
    unsigned long arrivals, overlap_passed, overlap_failed;
} GateStats;

typedef struct {
    int mode, rc;
    char *reply;
    Py_ssize_t reply_size;
    PyThread_type_lock barrier;
    unsigned long arrivals;
} GateContext;

enum { GATE_ECHO, GATE_RAW, GATE_EMPTY, GATE_HUGE, GATE_PENDING, GATE_DETACH, GATE_OVERLAP };
static xt_mutex_t stats_lock = XT_MUTEX_INIT;
static GateStats stats;
static GateContext *current_context;
static void *response_buffers[128];

static void observed_bridge_free(void *pointer) {
    xt_mutex_lock(&stats_lock);
    for (size_t i = 0; i < 128; i++) {
        if (pointer != NULL && response_buffers[i] == pointer) {
            response_buffers[i] = NULL;
            stats.freed++;
            stats.outstanding--;
            break;
        }
    }
    xt_mutex_unlock(&stats_lock);
    free(pointer);
}

static int tracked_copy(EXLPythonBridgeBuffer *output, const char *bytes, size_t size) {
    int rc = EXLPythonBridgeBufferCopy(output, bytes, size);
    if (rc != 0) return rc;
    xt_mutex_lock(&stats_lock);
    for (size_t i = 0; i < 128; i++) {
        if (response_buffers[i] == NULL) {
            response_buffers[i] = output->bytes;
            stats.buffers++;
            stats.outstanding++;
            xt_mutex_unlock(&stats_lock);
            return 0;
        }
    }
    xt_mutex_unlock(&stats_lock);
    EXLPythonBridgeBufferFree(output);
    return 71;
}

static void release_gate_context(void *opaque) {
    GateContext *context = opaque;
    xt_mutex_lock(&stats_lock);
    stats.released++;
    if (stats.active != 0) stats.released_active++;
    if (current_context == context) current_context = NULL;
    xt_mutex_unlock(&stats_lock);
    if (context->barrier) PyThread_free_lock(context->barrier);
    free(context->reply);
    free(context);
}

static int gate_recorder(void *opaque, const char *wire, size_t wire_size,
                         const char *owner, size_t owner_size,
                         EXLPythonBridgeBuffer *response) {
    GateContext *context = opaque;
    PyObject *json = NULL, *loads = NULL, *dumps = NULL;
    PyObject *text = NULL, *request = NULL, *identity = NULL, *envelope = NULL, *encoded = NULL;
    int status = 73;
    int pending = context->mode == GATE_PENDING;
    int configured_rc = context->rc;
    xt_mutex_lock(&stats_lock);
    stats.calls++;
    stats.active++;
    if (stats.active > stats.peak_active) stats.peak_active = stats.active;
    xt_mutex_unlock(&stats_lock);
    if (!PyGILState_Check()) {
        xt_mutex_lock(&stats_lock); stats.gil_faults++; xt_mutex_unlock(&stats_lock);
        goto done;
    }
    if (context->mode == GATE_EMPTY) { status = configured_rc; goto done; }
    if (context->mode == GATE_RAW || context->mode == GATE_HUGE || pending) {
        const char *bytes = pending ? "{\"ok\":true,\"value\":{\"fixture\":true}}" : context->reply;
        size_t size = pending ? strlen(bytes) : (size_t)context->reply_size;
        status = tracked_copy(response, bytes, size);
        if (status == 0 && context->mode == GATE_HUGE) response->count = SIZE_MAX;
        if (status == 0) status = configured_rc;
        goto done;
    }
    json = PyImport_ImportModule("json");
    loads = json ? PyObject_GetAttrString(json, "loads") : NULL;
    dumps = json ? PyObject_GetAttrString(json, "dumps") : NULL;
    text = PyUnicode_DecodeUTF8(wire, (Py_ssize_t)wire_size, "strict");
    request = text && loads ? PyObject_CallOneArg(loads, text) : NULL;
    identity = PyUnicode_DecodeUTF8(owner, (Py_ssize_t)owner_size, "strict");
    if (!request || !identity || !dumps || !PyDict_Check(request)) goto done;

    if (context->mode == GATE_DETACH) {
        if (EXLPythonBridgeUninstallDispatcher(gate_recorder, context) != 0) goto done;
        xt_mutex_lock(&stats_lock);
        int retained = current_context == context && stats.released_active == 0;
        if (retained) stats.retained_checks++;
        xt_mutex_unlock(&stats_lock);
        if (!retained) { status = 74; goto done; }
    }
    if (context->mode == GATE_OVERLAP) {
        PyObject *operation = PyDict_GetItemString(request, "operation");
        if (operation && PyUnicode_Check(operation) && PyUnicode_CompareWithASCIIString(operation, "check") == 0) {
            xt_mutex_lock(&stats_lock);
            unsigned long order = ++context->arrivals;
            stats.arrivals++;
            xt_mutex_unlock(&stats_lock);
            if (order == 1) {
                /* No SaveThread: the first owner holds its GIL while the second
                 * must enter this same C callback with its independent GIL. */
                PyLockStatus acquired = PyThread_acquire_lock_timed(context->barrier, 2000000, 0);
                xt_mutex_lock(&stats_lock);
                if (acquired == PY_LOCK_ACQUIRED) stats.overlap_passed++;
                else stats.overlap_failed++;
                xt_mutex_unlock(&stats_lock);
                if (acquired != PY_LOCK_ACQUIRED) { status = 75; goto done; }
            } else if (order == 2) {
                PyThread_release_lock(context->barrier);
            } else { status = 76; goto done; }
        }
    }
    int64_t interpreter = PyInterpreterState_GetID(PyThreadState_GetInterpreter(PyThreadState_Get()));
    if (interpreter < 0 || PyErr_Occurred()) goto done;
    envelope = Py_BuildValue("{s:O,s:{s:s,s:O,s:O,s:L,s:k,s:O}}",
        "ok", Py_True, "value", "fixture", "native-C-recorder",
        "request", request, "caller", identity, "interpreter_id", (long long)interpreter,
        "thread_id", PyThread_get_thread_ident(), "gil_held", Py_True);
    encoded = envelope ? PyObject_CallOneArg(dumps, envelope) : NULL;
    if (encoded) {
        Py_ssize_t size;
        const char *bytes = PyUnicode_AsUTF8AndSize(encoded, &size);
        if (bytes) status = tracked_copy(response, bytes, (size_t)size);
    }
done:
    Py_XDECREF(encoded); Py_XDECREF(envelope); Py_XDECREF(identity);
    Py_XDECREF(request); Py_XDECREF(text); Py_XDECREF(dumps); Py_XDECREF(loads); Py_XDECREF(json);
    xt_mutex_lock(&stats_lock); stats.active--; xt_mutex_unlock(&stats_lock);
    if (pending) PyErr_SetString(PyExc_ValueError, "fixture deliberately left a pending exception");
    return status;
}

static PyObject *fixture_install(PyObject *self, PyObject *args) {
    const char *mode, *reply = "";
    Py_ssize_t size = 0;
    int rc = 0, which = -1;
    (void)self;
    if (!PyArg_ParseTuple(args, "s|y#i:install", &mode, &reply, &size, &rc)) return NULL;
    const char *names[] = {"echo", "raw", "empty", "huge", "pending", "detach", "overlap"};
    for (int i = 0; i < 7; i++) if (strcmp(mode, names[i]) == 0) which = i;
    if (which < 0 || size > 65536) {
        PyErr_SetString(PyExc_ValueError, "fixture mode/reply exceeds bound"); return NULL;
    }
    GateContext *context = calloc(1, sizeof(*context));
    if (!context) return PyErr_NoMemory();
    context->mode = which; context->rc = rc; context->reply_size = size;
    context->reply = malloc((size_t)size + 1);
    if (!context->reply) { free(context); return PyErr_NoMemory(); }
    memcpy(context->reply, reply, (size_t)size); context->reply[size] = 0;
    if (which == GATE_OVERLAP) {
        context->barrier = PyThread_allocate_lock();
        if (!context->barrier) { free(context->reply); free(context); return PyErr_NoMemory(); }
        PyThread_acquire_lock(context->barrier, WAIT_LOCK);
    }
    int status = EXLPythonBridgeInstallDispatcher(gate_recorder, context, release_gate_context);
    if (status != 0) {
        if (context->barrier) PyThread_free_lock(context->barrier);
        free(context->reply); free(context);
    } else {
        xt_mutex_lock(&stats_lock); current_context = context; stats.contexts++; xt_mutex_unlock(&stats_lock);
    }
    return PyLong_FromLong(status);
}

static PyObject *fixture_uninstall(PyObject *self, PyObject *unused) {
    (void)self; (void)unused;
    xt_mutex_lock(&stats_lock); GateContext *context = current_context; xt_mutex_unlock(&stats_lock);
    return PyLong_FromLong(context ? EXLPythonBridgeUninstallDispatcher(gate_recorder, context) : -1);
}

static PyObject *fixture_wrong_detach(PyObject *self, PyObject *unused) {
    int other_context = 0;
    (void)self; (void)unused;
    return PyLong_FromLong(EXLPythonBridgeUninstallDispatcher(gate_recorder, &other_context));
}

static PyObject *fixture_metrics(PyObject *self, PyObject *unused) {
    (void)self; (void)unused;
    xt_mutex_lock(&stats_lock); GateStats value = stats; xt_mutex_unlock(&stats_lock);
    return Py_BuildValue("{s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k,s:k}",
        "calls", value.calls, "active", value.active, "peak_active", value.peak_active,
        "gil_faults", value.gil_faults, "contexts", value.contexts, "released", value.released,
        "released_active", value.released_active, "retained_checks", value.retained_checks,
        "buffers", value.buffers, "freed", value.freed, "outstanding", value.outstanding,
        "legacy_calls", value.legacy_calls, "arrivals", value.arrivals,
        "overlap_passed", value.overlap_passed, "overlap_failed", value.overlap_failed);
}

static PyObject *fixture_clear(PyObject *self, PyObject *bridge) {
    (void)self;
    PyModuleDef *definition = PyModule_Check(bridge) ? PyModule_GetDef(bridge) : NULL;
    if (!definition || !definition->m_clear) {
        PyErr_SetString(PyExc_TypeError, "fixture requires the actual bridge module clear slot"); return NULL;
    }
    if (definition->m_clear(bridge) < 0 || definition->m_clear(bridge) < 0) return NULL;
    Py_RETURN_NONE;
}

static int legacy_forgery(const char *fqcn, const char *member, const char *args, char **result) {
    (void)fqcn; (void)member; (void)args;
    const char text[] = "{\"legacy_forgery\":true}";
    xt_mutex_lock(&stats_lock); stats.legacy_calls++; xt_mutex_unlock(&stats_lock);
    *result = malloc(sizeof(text));
    if (!*result) return -1;
    memcpy(*result, text, sizeof(text));
    return 0;
}

static PyObject *fixture_legacy_pointer(PyObject *self, PyObject *unused) {
    (void)self; (void)unused;
    return PyLong_FromVoidPtr((void *)legacy_forgery);
}

static PyMethodDef fixture_methods[] = {
    {"install", fixture_install, METH_VARARGS, NULL},
    {"uninstall", fixture_uninstall, METH_NOARGS, NULL},
    {"wrong_detach", fixture_wrong_detach, METH_NOARGS, NULL},
    {"metrics", fixture_metrics, METH_NOARGS, NULL},
    {"clear_bridge", fixture_clear, METH_O, NULL},
    {"legacy_pointer", fixture_legacy_pointer, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};
static PyModuleDef fixture_definition = {
    PyModuleDef_HEAD_INIT, .m_name = "_elyx_c_gate_fixture", .m_size = -1, .m_methods = fixture_methods
};
PyMODINIT_FUNC PyInit__elyx_c_gate_fixture(void) { return PyModule_Create(&fixture_definition); }
