/* Diagnostic only. Real CPython 3.12 isolated configuration; no bypass of
 * check_multi_interp_extensions and no changes to the production engine. */
#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int add_path(PyConfig *config, const char *root, const char *suffix) {
    char path[8192];
    if (snprintf(path, sizeof(path), "%s/%s", root, suffix) >= sizeof(path)) return -1;
    wchar_t *wide = Py_DecodeLocale(path, NULL);
    if (!wide) return -1;
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide);
    PyMem_RawFree(wide);
    return PyStatus_Exception(status) ? -1 : 0;
}

static char *run_check(const char *package, const char *module_names) {
    PyObject *module = PyImport_ImportModule("native_dependency_checks");
    if (!module) { PyErr_Print(); return NULL; }
    PyObject *names = PyUnicode_FromString(module_names);
    PyObject *separator = PyUnicode_FromString(",");
    PyObject *list = names && separator ? PyUnicode_Split(names, separator, -1) : NULL;
    PyObject *result = list ? PyObject_CallMethod(module, "check", "sO", package, list) : NULL;
    const char *text = result ? PyUnicode_AsUTF8(result) : NULL;
    char *copy = text ? strdup(text) : NULL;
    if (!copy) PyErr_Print();
    Py_XDECREF(result); Py_XDECREF(list); Py_XDECREF(separator); Py_XDECREF(names); Py_DECREF(module);
    return copy;
}

int main(int argc, char **argv) {
    /* root, package, comma-separated extension modules, main|own-gil, report */
    if (argc != 6) return 2;
    int own = strcmp(argv[4], "own-gil") == 0;
    if (!own && strcmp(argv[4], "main") != 0) return 2;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    char home[8192];
    if (snprintf(home, sizeof(home), "%s/python-stdlib", argv[1]) >= sizeof(home)) return 2;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.executable, argv[0]);
    if (PyStatus_Exception(status) || add_path(&config, argv[1], "python-stdlib/lib/python3.12") ||
        add_path(&config, argv[1], "python-stdlib/lib/python3.12/lib-dynload") ||
        add_path(&config, argv[1], "python/native-vendor") || add_path(&config, argv[1], ".")) return 3;
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) { fprintf(stderr, "%s\n", status.err_msg); return 4; }
    if (PyRun_SimpleString("import _datetime") < 0) return 5;
    PyThreadState *main_state = PyThreadState_Get();
    char *results[2] = {NULL, NULL};
    int count = own ? 2 : 1;
    for (int index = 0; index < count; index++) {
        PyThreadState *child = NULL;
        if (own) {
            PyInterpreterConfig isolated = {
                .use_main_obmalloc = 0, .allow_fork = 0, .allow_exec = 0,
                .allow_threads = 0, .allow_daemon_threads = 0,
                .check_multi_interp_extensions = 1, .gil = PyInterpreterConfig_OWN_GIL,
            };
            status = Py_NewInterpreterFromConfig(&child, &isolated);
            if (PyStatus_Exception(status)) { fprintf(stderr, "%s\n", status.err_msg); return 6; }
        }
        results[index] = run_check(argv[2], argv[3]);
        if (own) { Py_EndInterpreter(child); PyEval_RestoreThread(main_state); }
        if (!results[index]) return 7;
    }
    PyObject *json = PyImport_ImportModule("json");
    PyObject *list = PyList_New(count);
    if (!json || !list) { PyErr_Print(); return 8; }
    int supported = own;
    for (int index = 0; index < count; index++) {
        PyObject *result = PyObject_CallMethod(json, "loads", "s", results[index]);
        free(results[index]);
        if (!result) return 8;
        if (PyDict_GetItemString(result, "ok") != Py_True) supported = 0;
        PyList_SET_ITEM(list, index, result);
    }
    /* Evidence comes from the executing runtime, not the compile-time header. */
    const char *runtime_version = Py_GetVersion();
    size_t version_size = strcspn(runtime_version, " ");
    char version[32];
    if (version_size >= sizeof(version)) return 9;
    memcpy(version, runtime_version, version_size); version[version_size] = '\0';
    const char *platform = PyUnicode_AsUTF8(PySys_GetObject("platform"));
    if (!platform) return 9;
    PyObject *report = Py_BuildValue("{s:s,s:s,s:s,s:s,s:i,s:i,s:O,s:O,s:O}",
        "actual_cpython", version, "platform", platform, "package", argv[2], "mode", argv[4],
        "check_multi_interp_extensions", 1, "own_gil_interpreters", own ? 2 : 0,
        "own_gil_supported", supported ? Py_True : Py_False, "native_completed", Py_True, "results", list);
    PyObject *encoded = report ? PyObject_CallMethod(json, "dumps", "O", report) : NULL;
    const char *text = encoded ? PyUnicode_AsUTF8(encoded) : NULL;
    char *copy = text ? strdup(text) : NULL;
    Py_XDECREF(encoded); Py_XDECREF(report); Py_DECREF(list); Py_DECREF(json);
    if (!copy) return 9;
    /* Publish only after successful interpreter/process teardown. */
    if (Py_FinalizeEx() < 0) { free(copy); return 10; }
    FILE *output = fopen(argv[5], "wb");
    if (!output) { free(copy); return 11; }
    fputs(copy, output); fputc('\n', output); fclose(output); free(copy);
    return 0;
}
