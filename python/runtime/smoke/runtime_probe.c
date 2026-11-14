#include <Python.h>
#include <stdio.h>
#include "EXLPythonBridge.h"
#include "runtime_probe.h"

#if PY_VERSION_HEX < 0x030C0000
#error "The runtime probe requires the public CPython 3.12 interpreter API"
#endif

static int add_path(PyConfig *config, const char *path) {
    wchar_t *wide = Py_DecodeLocale(path, NULL);
    if (!wide) return -1;
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide);
    PyMem_RawFree(wide);
    return PyStatus_Exception(status) ? -1 : 0;
}

static int script(const char *source) {
    return PyRun_SimpleString(source);
}

static int create_isolated(PyThreadState **state) {
    PyInterpreterConfig config = {
        .use_main_obmalloc = 0,
        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 0,
        .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1,
        .gil = PyInterpreterConfig_OWN_GIL,
    };
    PyStatus status = Py_NewInterpreterFromConfig(state, &config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "Subinterpreter: %s\n", status.err_msg ? status.err_msg : "creation failed");
        return -1;
    }
    return 0;
}

int EXLRunRuntimeProbe(const char *home, const char *stdlib_path,
                      const char *dynload_path, const char *report_path) {
    FILE *initial = fopen(report_path, "w");
    if (!initial) return 1;
    fputs("{\"ok\":false,\"phase\":\"initializing\"}\n", initial);
    fclose(initial);
    if (EXLRegisterPythonBridge() < 0) return 2;

    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) return 3;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.site_import = 0;
    config.parse_argv = 0;
    if (home) {
        status = PyConfig_SetBytesString(&config, &config.home, home);
        if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return 4; }
    }
    if (stdlib_path && dynload_path) {
        config.module_search_paths_set = 1;
        if (add_path(&config, stdlib_path) < 0 || add_path(&config, dynload_path) < 0) {
            PyConfig_Clear(&config);
            return 5;
        }
    }
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "Python initialization: %s\n", status.err_msg ? status.err_msg : "failed");
        return 6;
    }
    PyThreadState *main_state = PyThreadState_Get();
    PyObject *globals = PyModule_GetDict(PyImport_AddModule("__main__"));
    PyObject *report = PyUnicode_DecodeFSDefault(report_path);
    if (!report || PyDict_SetItemString(globals, "_report_path", report) < 0) return 7;
    Py_DECREF(report);
    if (script(
        "import sys, json, ssl, hashlib, sqlite3, socket, asyncio, ctypes, lzma, bz2, zlib, math, select\n"
        "import _ssl, _hashlib, _sqlite3, _exteraless_bridge as bridge\n"
        "assert sys.version_info[:2] == (3, 12)\n"
        "assert hashlib.sha256(b'abc').hexdigest() == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'\n"
        "db = sqlite3.connect(':memory:')\n"
        "assert db.execute('select 6 * 7').fetchone() == (42,)\n"
        "db.close()\n"
        "sock = socket.socket(); sock.close()\n"
        "assert lzma.decompress(lzma.compress(b'probe')) == b'probe'\n"
        "assert bz2.decompress(bz2.compress(b'probe')) == b'probe'\n"
        "assert zlib.decompress(zlib.compress(b'probe')) == b'probe'\n"
        "main_object = object(); main_handle = bridge.xt_register_handle(main_object)\n"
        "assert bridge.xt_resolve_handle(main_handle) is main_object\n"
    ) < 0) return 8;

    /* Two live OWN_GIL interpreters. Exchange only C thread-state pointers;
     * no PyObject reference or handle namespace is passed between them. */
    PyThreadState *first = NULL, *second = NULL;
    if (create_isolated(&first) < 0) return 9;
    if (script(
        "import _exteraless_bridge as bridge\n"
        "import ssl, sqlite3, hashlib, math\n"
        "assert hashlib.sha256(b'abc').hexdigest().startswith('ba7816bf')\n"
        "db = sqlite3.connect(':memory:'); assert db.execute('select 42').fetchone() == (42,); db.close()\n"
        "assert bridge.xt_handle_count() == 0\n"
        "first_object = object(); first_handle = bridge.xt_register_handle(first_object)\n"
        "assert bridge.xt_resolve_handle(first_handle) is first_object\n"
    ) < 0) return 10;
    PyEval_SaveThread();
    PyEval_RestoreThread(main_state);

    if (create_isolated(&second) < 0) return 11;
    if (script(
        "import _exteraless_bridge as bridge\n"
        "import ssl, sqlite3\n"
        "assert bridge.xt_handle_count() == 0\n"
        "second_object = object(); second_handle = bridge.xt_register_handle(second_object)\n"
        "assert bridge.xt_resolve_handle(second_handle) is second_object\n"
        "assert bridge.xt_release_handle(second_handle)\n"
    ) < 0) return 12;
    Py_EndInterpreter(second);
    PyEval_RestoreThread(main_state);
    PyEval_SaveThread();
    PyEval_RestoreThread(first);
    if (script(
        "assert bridge.xt_resolve_handle(first_handle) is first_object\n"
        "assert bridge.xt_release_handle(first_handle)\n"
    ) < 0) return 13;
    Py_EndInterpreter(first);
    PyEval_RestoreThread(main_state);
    if (script(
        "assert bridge.xt_resolve_handle(main_handle) is main_object\n"
        "assert bridge.xt_release_handle(main_handle)\n"
        "result = dict(ok=True, python=sys.version, platform=sys.platform, openssl=ssl.OPENSSL_VERSION,\n"
        "              sqlite=sqlite3.sqlite_version, own_gil_interpreters=2, builtin_bridge=True,\n"
        "              extension_paths=[_ssl.__file__, _hashlib.__file__, _sqlite3.__file__])\n"
        "with open(_report_path, 'w', encoding='utf-8') as f: json.dump(result, f, indent=2)\n"
        "print('EXTERALESS_RUNTIME_PROBE_OK', flush=True)\n"
    ) < 0) return 14;
    return Py_FinalizeEx() < 0 ? 15 : 0;
}

#ifdef EXL_RUNTIME_PROBE_MAIN
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fputs("usage: runtime-probe report.json [python-home]\n", stderr); return 2; }
    return EXLRunRuntimeProbe(argc == 3 ? argv[2] : NULL, NULL, NULL, argv[1]);
}
#endif
