#ifndef EXL_CPYTHON312_COMPAT_H
#define EXL_CPYTHON312_COMPAT_H

#include <Python.h>

/* Internal, version-pinned compatibility layer; not exposed to Swift. */
void EXLPython312EnsureGIL(PyThreadState *state);
/* Called with state current and its GIL held. Refuses outstanding threads;
 * otherwise prevents Python finalizers from starting new threads. */
int EXLPython312PrepareEnd(PyThreadState *state);

#endif
