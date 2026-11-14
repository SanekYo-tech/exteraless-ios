#include <Python.h>
#include "EXLPythonBridge.h"

PyMODINIT_FUNC PyInit__exteraless_bridge(void);

int EXLRegisterPythonBridge(void) {
    if (Py_IsInitialized()) {
        return -1;
    }
    return PyImport_AppendInittab("_exteraless_bridge", PyInit__exteraless_bridge);
}
