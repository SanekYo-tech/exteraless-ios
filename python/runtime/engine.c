#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include "EXLPythonBridge.h"
#include "EXLPythonEngine.h"
#include "cpython312_compat.h"

#if PY_MAJOR_VERSION != 3 || PY_MINOR_VERSION != 12
#error "The embedded engine is pinned to CPython 3.12"
#endif

/* This lock protects native bookkeeping only, never Python execution. */
#ifdef _WIN32
#include <windows.h>
static SRWLOCK state_lock = SRWLOCK_INIT;
static void lock_state(void) { AcquireSRWLockExclusive(&state_lock); }
static void unlock_state(void) { ReleaseSRWLockExclusive(&state_lock); }
#else
#include <pthread.h>
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static void lock_state(void) { pthread_mutex_lock(&state_lock); }
static void unlock_state(void) { pthread_mutex_unlock(&state_lock); }
#endif

enum ProcessPhase { IDLE, INITIALIZING, READY, FINALIZING, STOPPED };
typedef struct Interpreter {
    int64_t id;
    unsigned long owner;
    PyThreadState *state;
    int busy;
    struct Interpreter *next;
} Interpreter;

static enum ProcessPhase process_phase = IDLE;
static unsigned long process_owner;
static PyThreadState *main_state;
static PyInterpreterState *main_interpreter;
static Interpreter *interpreters;
static size_t live_interpreters; /* Includes reservations during creation. */
static int64_t next_id = 1;

#ifdef EXL_ENGINE_FAULT_INJECTION
static int injected_create_failure;
void EXLPythonTestFailNextCreate(int mode) {
    lock_state();
    injected_create_failure = mode;
    unlock_state();
}
#endif

static PyStatus create_subinterpreter(PyThreadState **state, const PyInterpreterConfig *config) {
#ifdef EXL_ENGINE_FAULT_INJECTION
    lock_state();
    int mode = injected_create_failure;
    injected_create_failure = 0;
    unlock_state();
    if (mode) {
        *state = NULL;
        if (mode == 1) PyEval_SaveThread();
        return PyStatus_Error("injected creation failure");
    }
#endif
    return Py_NewInterpreterFromConfig(state, config);
}

static void reset_buffer(EXLPythonBuffer *buffer) {
    if (buffer) { buffer->bytes = NULL; buffer->count = 0; }
}

void EXLPythonBufferFree(EXLPythonBuffer *buffer) {
    if (buffer) { free(buffer->bytes); reset_buffer(buffer); }
}

static int copy_buffer(EXLPythonBuffer *buffer, const char *bytes, size_t count) {
    if (!buffer) return 0;
    if (count == SIZE_MAX) return -1;
    buffer->bytes = malloc(count + 1);
    if (!buffer->bytes) return -1;
    memcpy(buffer->bytes, bytes, count);
    buffer->bytes[count] = 0;
    buffer->count = count;
    return 0;
}

static int fail(EXLPythonBuffer *error, const char *message) {
    copy_buffer(error, message, strlen(message));
    return -1;
}

static int fail_status(EXLPythonBuffer *error, PyStatus status) {
    return fail(error, status.err_msg ? status.err_msg : "CPython requested exit during initialization");
}

/* Called only under the affected interpreter's GIL. PyErr_Print would run
 * sys.excepthook and may terminate the process for SystemExit. */
static int fail_python(EXLPythonBuffer *error) {
    PyObject *exception = PyErr_GetRaisedException();
    PyObject *text = exception ? PyObject_Repr(exception) : NULL;
    Py_ssize_t count = 0;
    const char *utf8 = text ? PyUnicode_AsUTF8AndSize(text, &count) : NULL;
    if (utf8) copy_buffer(error, utf8, (size_t)count);
    else fail(error, "Python exception (unable to format)");
    Py_XDECREF(text);
    Py_XDECREF(exception);
    PyErr_Clear();
    return -1;
}

const char *EXLPythonVersion(void) { return Py_GetVersion(); }

int EXLPythonIsInitialized(void) {
    lock_state();
    int initialized = process_phase == READY;
    unlock_state();
    return initialized;
}

int EXLPythonInitialize(const EXLPythonProcessConfiguration *configuration,
                        EXLPythonBuffer *error) {
    reset_buffer(error);
    if (!configuration || (configuration->module_search_path_count && !configuration->module_search_paths))
        return fail(error, "Invalid Python process configuration");
    const char *linked_version = Py_GetVersion();
    size_t version_length = strlen(PY_VERSION);
    if (strncmp(linked_version, PY_VERSION, version_length) != 0 || linked_version[version_length] != ' ')
        return fail(error, "CPython headers and linked runtime must have the same patch version");
    lock_state();
    if (process_phase != IDLE || Py_IsInitialized()) {
        unlock_state();
        return fail(error, "CPython process initialization is exclusive and one-shot");
    }
    process_phase = INITIALIZING;
    process_owner = PyThread_get_thread_ident();
    unlock_state();

    int result = -1;
    if (EXLRegisterPythonBridge() < 0) {
        fail(error, "Could not register the built-in Python bridge");
        goto finished;
    }
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
#ifdef EXL_ENGINE_DEBUG_MEMORY
    pre.allocator = PYMEM_ALLOCATOR_DEBUG;
#endif
    PyStatus status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) {
        fail_status(error, status);
        goto finished;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.parse_argv = 0;
    config.site_import = 0;
#ifdef EXL_ENGINE_DEBUG_MEMORY
    config.faulthandler = 1;
#endif
    config.write_bytecode = !!configuration->write_bytecode;
    config.install_signal_handlers = !!configuration->install_signal_handlers;
#define SET_CONFIG_STRING(field, value) do { \
    if (value) { \
        status = PyConfig_SetBytesString(&config, &config.field, value); \
        if (PyStatus_Exception(status)) goto configured; \
    } \
} while (0)
    SET_CONFIG_STRING(program_name, configuration->program_name);
    SET_CONFIG_STRING(home, configuration->home);
    SET_CONFIG_STRING(executable, configuration->executable);
#undef SET_CONFIG_STRING
    if (configuration->module_search_path_count) {
        config.module_search_paths_set = 1;
        for (size_t i = 0; i < configuration->module_search_path_count; i++) {
            const char *path = configuration->module_search_paths[i];
            if (!path) { status = PyStatus_Error("NULL module search path"); goto configured; }
            wchar_t *wide = Py_DecodeLocale(path, NULL);
            if (!wide) { status = PyStatus_NoMemory(); goto configured; }
            status = PyWideStringList_Append(&config.module_search_paths, wide);
            PyMem_RawFree(wide);
            if (PyStatus_Exception(status)) goto configured;
        }
    }
    status = Py_InitializeFromConfig(&config);
configured:
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fail_status(error, status);
        goto finished;
    }
    /* In the pinned 3.12 runtime _datetime is still a legacy extension with
     * process-global static types. Initialize it under the MAIN GIL before
     * concurrent subinterpreter imports (sqlite3 imports datetime too). The
     * per-interpreter extension checks remain enabled; no module is shared by
     * overriding those checks. */
    PyObject *datetime = PyImport_ImportModule("_datetime");
    if (!datetime) {
        fail_python(error);
        Py_FinalizeEx();
        goto finished;
    }
    Py_DECREF(datetime);
    main_interpreter = PyThreadState_GetInterpreter(PyThreadState_Get());
    main_state = PyEval_SaveThread();
    result = 0;
finished:
    lock_state();
    process_phase = result == 0 ? READY : STOPPED;
    unlock_state();
    return result;
}

int EXLPythonFinalize(EXLPythonBuffer *error) {
    reset_buffer(error);
    lock_state();
    const char *problem = NULL;
    if (process_phase != READY) problem = "CPython is not running";
    else if (process_owner != PyThread_get_thread_ident()) problem = "Finalize must run on the initialization thread";
    else if (live_interpreters) problem = "Cannot finalize CPython while interpreters are alive or being created";
    if (problem) { unlock_state(); return fail(error, problem); }
    process_phase = FINALIZING;
    unlock_state();
    PyEval_RestoreThread(main_state);
    int status = Py_FinalizeEx();
    lock_state();
    main_state = NULL;
    main_interpreter = NULL;
    process_phase = STOPPED;
    unlock_state();
    return status < 0 ? fail(error, "Py_FinalizeEx failed") : 0;
}

int EXLPythonCreateInterpreter(const EXLPythonInterpreterConfiguration *configuration,
                               int64_t *reference, EXLPythonBuffer *error) {
    reset_buffer(error);
    if (reference) *reference = 0;
    if (!configuration || !reference) return fail(error, "Invalid interpreter configuration or output");
    if (configuration->use_main_obmalloc && configuration->own_gil)
        return fail(error, "An own-GIL interpreter requires its own object allocator");
    if (!configuration->use_main_obmalloc && !configuration->check_multi_interp_extensions)
        return fail(error, "An isolated object allocator requires multi-interpreter extension checks");
    Interpreter *entry = calloc(1, sizeof(*entry));
    if (!entry) return fail(error, "Could not allocate interpreter bookkeeping");
    lock_state();
    if (process_phase != READY || next_id == INT64_MAX) {
        unlock_state();
        free(entry);
        return fail(error, "CPython is not accepting new interpreters");
    }
    entry->id = next_id++;
    entry->owner = PyThread_get_thread_ident();
    live_interpreters++;
    PyInterpreterState *parent = main_interpreter;
    unlock_state();

    /* Attach a temporary MAIN-interpreter state on this worker. Never use
     * PyGILState_Ensure with subinterpreters and never migrate main_state. */
    PyThreadState *temporary = PyThreadState_New(parent);
    if (!temporary) {
        fail(error, "Could not create a temporary main-interpreter thread state");
        goto failed;
    }
    PyEval_RestoreThread(temporary);
    PyInterpreterConfig config = {
        .use_main_obmalloc = !!configuration->use_main_obmalloc,
        .allow_fork = !!configuration->allow_fork,
        .allow_exec = !!configuration->allow_exec,
        .allow_threads = !!configuration->allow_threads,
        .allow_daemon_threads = !!configuration->allow_daemon_threads,
        .check_multi_interp_extensions = !!configuration->check_multi_interp_extensions,
        .gil = configuration->own_gil ? PyInterpreterConfig_OWN_GIL : PyInterpreterConfig_SHARED_GIL,
    };
    PyStatus status = create_subinterpreter(&entry->state, &config);
    if (PyStatus_Exception(status) || !entry->state) {
        if (PyStatus_Exception(status)) fail_status(error, status);
        else fail(error, "Could not allocate a CPython subinterpreter");
        EXLPython312EnsureGIL(temporary);
        PyThreadState_Clear(temporary);
        PyThreadState_DeleteCurrent();
        goto failed;
    }
    /* Creation switched to the new interpreter and its GIL. Detach it, then
     * destroy the temporary main state under the MAIN GIL. Return detached. */
    PyEval_SaveThread();
    PyEval_RestoreThread(temporary);
    PyThreadState_Clear(temporary);
    PyThreadState_DeleteCurrent();
    lock_state();
    entry->next = interpreters;
    interpreters = entry;
    *reference = entry->id;
    unlock_state();
    return 0;
failed:
    lock_state();
    live_interpreters--;
    unlock_state();
    free(entry);
    return -1;
}

/* Pins an entry by marking it busy before releasing the native lock. Neither
 * destruction nor reentrant execution can remove it while it is pinned. */
static Interpreter *begin_call(int64_t reference, EXLPythonBuffer *error) {
    lock_state();
    Interpreter *entry = interpreters;
    while (entry && entry->id != reference) entry = entry->next;
    const char *problem = NULL;
    if (process_phase != READY) problem = "CPython is not running";
    else if (!entry) problem = "Unknown or destroyed interpreter";
    else if (entry->owner != PyThread_get_thread_ident()) problem = "Interpreter called from the wrong native thread";
    else if (entry->busy) problem = "Reentrant interpreter execution is not supported";
    if (problem) { unlock_state(); fail(error, problem); return NULL; }
    entry->busy = 1;
    unlock_state();
    return entry;
}

int EXLPythonRunScript(int64_t reference, const char *source, size_t source_length,
                       EXLPythonBuffer *result, EXLPythonBuffer *error) {
    reset_buffer(result);
    reset_buffer(error);
    if (!result || !source || source_length == SIZE_MAX || memchr(source, 0, source_length))
        return fail(error, "Invalid Python source (including embedded NUL) or output");
    char *terminated = malloc(source_length + 1);
    if (!terminated) return fail(error, "Could not copy Python source");
    memcpy(terminated, source, source_length);
    terminated[source_length] = 0;
    Interpreter *entry = begin_call(reference, error);
    if (!entry) { free(terminated); return -1; }
    PyEval_RestoreThread(entry->state);
    int status = -1;
    PyObject *code = NULL, *value = NULL, *text = NULL;
    PyObject *module = PyImport_AddModule("__main__");
    PyObject *globals = module ? PyModule_GetDict(module) : NULL;
    if (!globals) goto executed;
    code = Py_CompileString(terminated, "<exteraless>", Py_eval_input);
    if (!code && PyErr_ExceptionMatches(PyExc_SyntaxError)) {
        PyErr_Clear();
        code = Py_CompileString(terminated, "<exteraless>", Py_file_input);
    }
    if (!code) goto executed;
    value = PyEval_EvalCode(code, globals, globals);
    if (!value) goto executed;
    text = PyUnicode_Check(value) ? Py_NewRef(value) : PyObject_Repr(value);
    if (!text) goto executed;
    Py_ssize_t count = 0;
    const char *utf8 = PyUnicode_AsUTF8AndSize(text, &count);
    if (!utf8) goto executed;
    status = copy_buffer(result, utf8, (size_t)count);
    if (status < 0) fail(error, "Could not copy Python result");
executed:
    if (status < 0 && (!error || !error->bytes)) fail_python(error);
    Py_XDECREF(text);
    Py_XDECREF(value);
    Py_XDECREF(code);
    entry->state = PyEval_SaveThread();
    free(terminated);
    lock_state();
    entry->busy = 0;
    unlock_state();
    return status;
}

int EXLPythonDestroyInterpreter(int64_t reference, EXLPythonBuffer *error) {
    reset_buffer(error);
    Interpreter *entry = begin_call(reference, error);
    if (!entry) return -1;
    PyEval_RestoreThread(entry->state);
    if (!EXLPython312PrepareEnd(entry->state)) {
        entry->state = PyEval_SaveThread();
        lock_state();
        entry->busy = 0;
        unlock_state();
        return fail(error, "Cannot destroy interpreter while additional Python threads are alive");
    }
    Py_EndInterpreter(entry->state);
    lock_state();
    Interpreter **link = &interpreters;
    while (*link != entry) link = &(*link)->next;
    *link = entry->next;
    live_interpreters--;
    unlock_state();
    free(entry);
    return 0;
}
