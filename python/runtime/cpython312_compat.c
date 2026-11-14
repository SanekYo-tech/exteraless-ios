/* CPython 3.12 has an early Py_NewInterpreterFromConfig error path that
 * restores the caller's tstate without reacquiring its GIL. The public
 * PyGILState_Check cannot distinguish this (disabled for subinterpreters).
 * Isolate the required private layout access in this one translation unit,
 * compiled against the SAME pinned runtime's internal headers. */
#define Py_BUILD_CORE_MODULE
#include <Python.h>
#include "internal/pycore_interp.h"
#include "internal/pycore_gil.h"
#include "cpython312_compat.h"

#if PY_MAJOR_VERSION != 3 || PY_MINOR_VERSION != 12
#error "This compatibility layer requires the matching CPython 3.12 headers"
#endif

void EXLPython312EnsureGIL(PyThreadState *state) {
    struct _gil_runtime_state *gil = PyThreadState_GetInterpreter(state)->ceval.gil;
    /* locked and last_holder must be inspected together under the GIL's own
     * mutex: another worker can acquire it between separate atomic reads. */
#ifdef _WIN32
#if _PY_EMULATED_WIN_CV
    EnterCriticalSection(&gil->mutex);
#else
    AcquireSRWLockExclusive(&gil->mutex);
#endif
#else
    pthread_mutex_lock(&gil->mutex);
#endif
    int owned = _Py_atomic_load_relaxed(&gil->locked) == 1 &&
                _Py_atomic_load_relaxed(&gil->last_holder) == (uintptr_t)state;
#ifdef _WIN32
#if _PY_EMULATED_WIN_CV
    LeaveCriticalSection(&gil->mutex);
#else
    ReleaseSRWLockExclusive(&gil->mutex);
#endif
#else
    pthread_mutex_unlock(&gil->mutex);
#endif
    if (!owned) PyEval_RestoreThread(state);
}

int EXLPython312PrepareEnd(PyThreadState *state) {
    PyInterpreterState *interp = PyThreadState_GetInterpreter(state);
    for (PyThreadState *thread = PyInterpreterState_ThreadHead(interp); thread;
         thread = PyThreadState_Next(thread)) {
        if (thread != state) return 0;
    }
    /* Py_EndInterpreter only sets the finalizing tstate after running atexit
     * handlers. Close the _thread/threading creation gate before those run. */
    interp->feature_flags &= ~(Py_RTFLAGS_THREADS | Py_RTFLAGS_DAEMON_THREADS);
    return 1;
}
