#ifndef EXL_PYTHON_BRIDGE_H
#define EXL_PYTHON_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Register the built-in bridge before Py_InitializeFromConfig. Returns -1
 * if Python is already initialized or registration failed. No Python headers
 * are exposed to the Swift caller of this function. */
int EXLRegisterPythonBridge(void);

#ifdef __cplusplus
}
#endif
#endif
