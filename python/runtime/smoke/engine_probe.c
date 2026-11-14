#include <Python.h>
#include <stdio.h>
#include <string.h>
#include "EXLPythonEngine.h"
#include "engine_probe.h"

#ifdef EXL_ENGINE_FAULT_INJECTION
void EXLPythonTestFailNextCreate(int mode);
#endif

typedef struct {
    int index;
    int failed;
    int64_t reference;
    PyThread_type_lock ready;
    PyThread_type_lock proceed;
    PyThread_type_lock done;
} ProbeWorker;

static void problem(ProbeWorker *worker, const char *operation, const EXLPythonBuffer *error) {
    worker->failed = 1;
    fprintf(stderr, "ENGINE_PROBE worker=%d %s: %s\n", worker->index, operation,
            error && error->bytes ? error->bytes : "unexpected result");
}

static int expect(ProbeWorker *worker, const char *source, const char *expected, size_t count) {
    EXLPythonBuffer result = {0}, error = {0};
    int status = EXLPythonRunScript(worker->reference, source, strlen(source), &result, &error);
    if (status != 0 || result.count != count || !result.bytes || memcmp(result.bytes, expected, count))
        problem(worker, source, &error);
    EXLPythonBufferFree(&result);
    EXLPythonBufferFree(&error);
    return worker->failed ? -1 : 0;
}

static void expect_exception(ProbeWorker *worker, const char *source, const char *kind) {
    EXLPythonBuffer result = {0}, error = {0};
    int status = EXLPythonRunScript(worker->reference, source, strlen(source), &result, &error);
    if (status == 0 || !error.bytes || !strstr(error.bytes, kind)) problem(worker, source, &error);
    EXLPythonBufferFree(&result);
    EXLPythonBufferFree(&error);
}

static void worker_main(void *opaque) {
    ProbeWorker *worker = opaque;
    EXLPythonInterpreterConfiguration config = {
        .use_main_obmalloc = 0, .allow_fork = 0, .allow_exec = 0,
        .allow_threads = 0, .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1, .own_gil = 1,
    };
    EXLPythonBuffer error = {0};
    fprintf(stderr, "ENGINE_PROBE worker=%d creating\n", worker->index);
    if (EXLPythonCreateInterpreter(&config, &worker->reference, &error) != 0) {
        problem(worker, "create", &error);
    } else {
        fprintf(stderr, "ENGINE_PROBE worker=%d created\n", worker->index);
        const char *imports[] = {"import _exteraless_bridge as bridge", "import json", "import ssl", "import sqlite3", "import hashlib"};
        for (size_t i = 0; i < sizeof(imports) / sizeof(imports[0]); i++) {
            expect(worker, imports[i], "None", 4);
            fprintf(stderr, "ENGINE_PROBE worker=%d returned from %s\n", worker->index, imports[i]);
        }
        char setup[1024];
        snprintf(setup, sizeof(setup),
            "assert bridge.xt_handle_count() == 0\n"
            "payload = object(); handle = bridge.xt_register_handle(payload)\n"
            "label = %d\n"
            "counter = 0\n"
            "def fail_once():\n"
            "    global counter\n"
            "    counter += 1\n"
            "    raise SyntaxError('execution error, not a compile error')\n"
            "db = sqlite3.connect(':memory:')\n"
            "assert db.execute('select 42').fetchone() == (42,)\n"
            "db.close()\n", worker->index);
        expect(worker, setup, "None", 4);
        fprintf(stderr, "ENGINE_PROBE worker=%d bootstrap returned\n", worker->index);
    }
    EXLPythonBufferFree(&error);
    PyThread_release_lock(worker->ready);
    PyThread_acquire_lock(worker->proceed, WAIT_LOCK);
    PyThread_release_lock(worker->proceed);

    if (worker->reference) {
        char label[16];
        snprintf(label, sizeof(label), "%d", worker->index);
        expect(worker, "label", label, strlen(label));
        expect(worker, "bridge.xt_handle_count()", "1", 1);
        expect(worker, "bridge.xt_resolve_handle(handle) is payload", "True", 4);
        expect(worker, "json.dumps({'ok': True})", "{\"ok\": true}", 12);
        expect(worker, "'\\u041f\\u0440\\u0438\\u0432\\u0435\\u0442'", "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82", 12);
        expect(worker, "'a\\x00b'", "a\0b", 3);
        expect_exception(worker, "fail_once()", "SyntaxError");
        expect(worker, "counter", "1", 1); /* The throwing call was not retried. */
        expect_exception(worker, "__import__('sys').exit(19)", "SystemExit");
        expect_exception(worker, "def broken(", "SyntaxError");
        expect(worker, "6 * 7", "42", 2);

        EXLPythonBuffer result = {0};
        if (EXLPythonRunScript(worker->reference, "1\0+2", 4, &result, &error) == 0 ||
            !error.bytes || !strstr(error.bytes, "embedded NUL"))
            problem(worker, "embedded NUL source", &error);
        EXLPythonBufferFree(&result);
        EXLPythonBufferFree(&error);
        if (EXLPythonFinalize(&error) == 0 || !error.bytes || !strstr(error.bytes, "initialization thread"))
            problem(worker, "wrong-thread finalize", &error);
        EXLPythonBufferFree(&error);

        expect(worker, "bridge.xt_release_handle(handle)", "True", 4);
        if (EXLPythonDestroyInterpreter(worker->reference, &error) != 0)
            problem(worker, "destroy", &error);
        EXLPythonBufferFree(&error);
        expect_exception(worker, "42", "Unknown or destroyed interpreter");
    }
    PyThread_release_lock(worker->done);
}

static int check_live_thread_shutdown(void) {
    ProbeWorker worker = {.index = 3};
    EXLPythonInterpreterConfiguration config = {
        .allow_threads = 1, .check_multi_interp_extensions = 1, .own_gil = 1,
    };
    EXLPythonBuffer error = {0};
    if (EXLPythonCreateInterpreter(&config, &worker.reference, &error) != 0) {
        problem(&worker, "create raw-thread test", &error);
        EXLPythonBufferFree(&error);
        return -1;
    }
    /* _thread workers are not joined by threading._shutdown. A sentinel is
     * released by actual tstate teardown, so this test needs no timing sleep. */
    expect(&worker,
        "import _thread\n"
        "gate = _thread.allocate_lock(); gate.acquire()\n"
        "started = _thread.allocate_lock(); started.acquire()\n"
        "def raw_worker():\n"
        "    global finished\n"
        "    finished = _thread._set_sentinel(); finished.acquire()\n"
        "    started.release()\n"
        "    with gate: pass\n"
        "_thread.start_new_thread(raw_worker, ())\n"
        "started.acquire()\n", "None", 4);
    if (EXLPythonDestroyInterpreter(worker.reference, &error) == 0 ||
        !error.bytes || !strstr(error.bytes, "additional Python threads"))
        problem(&worker, "destroy must refuse a live _thread", &error);
    EXLPythonBufferFree(&error);
    expect(&worker, "gate.release(); finished.acquire()", "None", 4);
    if (EXLPythonDestroyInterpreter(worker.reference, &error) != 0)
        problem(&worker, "destroy after raw-thread exit", &error);
    EXLPythonBufferFree(&error);
    fprintf(stderr, "ENGINE_PROBE raw-thread shutdown refusal and cooperative completion checked\n");
    return worker.failed ? -1 : 0;
}

int EXLRunEngineProbe(const char *home, const char *stdlib_path,
                     const char *dynload_path, const char *executable_path,
                     const char *report_path) {
    FILE *report = fopen(report_path, "w");
    if (!report) return 1;
    fputs("{\"ok\":false,\"phase\":\"engine-initializing\"}\n", report);
    fclose(report);
    const char *paths[] = {stdlib_path, dynload_path};
    EXLPythonProcessConfiguration config = {
        .program_name = "exteraless-engine-probe", .home = home, .executable = executable_path,
        .module_search_paths = stdlib_path && dynload_path ? paths : NULL,
        .module_search_path_count = stdlib_path && dynload_path ? 2 : 0,
    };
    EXLPythonBuffer error = {0};
    if (EXLPythonInitialize(&config, &error) != 0) {
        fprintf(stderr, "ENGINE_PROBE initialization: %s\n", error.bytes ? error.bytes : "failed");
        EXLPythonBufferFree(&error);
        return 2;
    }
    if (!EXLPythonIsInitialized()) return 3;
    fprintf(stderr, "ENGINE_PROBE initialized %s\n", EXLPythonVersion());
    if (EXLPythonInitialize(&config, &error) == 0 || !error.bytes || !strstr(error.bytes, "one-shot")) return 8;
    EXLPythonBufferFree(&error);
    EXLPythonInterpreterConfiguration invalid = {
        .use_main_obmalloc = 1, .check_multi_interp_extensions = 1, .own_gil = 1,
    };
    int64_t invalid_reference = 0;
    if (EXLPythonCreateInterpreter(&invalid, &invalid_reference, &error) == 0 || invalid_reference != 0) return 9;
    EXLPythonBufferFree(&error);
#ifdef EXL_ENGINE_FAULT_INJECTION
    EXLPythonInterpreterConfiguration valid = {.check_multi_interp_extensions = 1, .own_gil = 1};
    for (int mode = 1; mode <= 2; mode++) {
        EXLPythonTestFailNextCreate(mode);
        if (EXLPythonCreateInterpreter(&valid, &invalid_reference, &error) == 0 || invalid_reference != 0 ||
            !error.bytes || !strstr(error.bytes, "injected creation failure")) return 10;
        EXLPythonBufferFree(&error);
    }
    fprintf(stderr, "ENGINE_PROBE both creation-failure GIL states recovered\n");
#endif

    ProbeWorker workers[2] = {0};
    for (int i = 0; i < 2; i++) {
        ProbeWorker *worker = &workers[i];
        worker->index = i + 1;
        worker->ready = PyThread_allocate_lock();
        worker->proceed = PyThread_allocate_lock();
        worker->done = PyThread_allocate_lock();
        if (!worker->ready || !worker->proceed || !worker->done) return 4;
        PyThread_acquire_lock(worker->ready, WAIT_LOCK);
        PyThread_acquire_lock(worker->proceed, WAIT_LOCK);
        PyThread_acquire_lock(worker->done, WAIT_LOCK);
        if (PyThread_start_new_thread(worker_main, worker) == PYTHREAD_INVALID_THREAD_ID) return 5;
    }
    for (int i = 0; i < 2; i++) PyThread_acquire_lock(workers[i].ready, WAIT_LOCK);
    int failed = workers[0].failed || workers[1].failed;
    if (!workers[0].reference || workers[0].reference == workers[1].reference) failed = 1;
    fprintf(stderr, "ENGINE_PROBE two worker-owned interpreters ready\n");
    if (EXLPythonFinalize(&error) == 0 || !error.bytes || !strstr(error.bytes, "interpreters are alive")) failed = 1;
    EXLPythonBufferFree(&error);
    EXLPythonBuffer result = {0};
    if (EXLPythonRunScript(workers[0].reference, "42", 2, &result, &error) == 0 ||
        !error.bytes || !strstr(error.bytes, "wrong native thread")) failed = 1;
    EXLPythonBufferFree(&result);
    EXLPythonBufferFree(&error);

    for (int i = 0; i < 2; i++) PyThread_release_lock(workers[i].proceed);
    for (int i = 0; i < 2; i++) {
        PyThread_acquire_lock(workers[i].done, WAIT_LOCK);
        failed |= workers[i].failed;
        PyThread_release_lock(workers[i].ready);
        PyThread_release_lock(workers[i].done);
        PyThread_free_lock(workers[i].ready);
        PyThread_free_lock(workers[i].proceed);
        PyThread_free_lock(workers[i].done);
    }
    if (check_live_thread_shutdown() != 0) failed = 1;
    if (EXLPythonFinalize(&error) != 0) {
        fprintf(stderr, "ENGINE_PROBE finalization: %s\n", error.bytes ? error.bytes : "failed");
        failed = 1;
    }
    EXLPythonBufferFree(&error);
    if (EXLPythonIsInitialized()) failed = 1;
    if (EXLPythonInitialize(&config, &error) == 0) failed = 1;
    EXLPythonBufferFree(&error);
    if (failed) return 6;
    report = fopen(report_path, "w");
    if (!report) return 7;
    fprintf(report, "{\"ok\":true,\"probe\":\"native-engine\",\"python\":\"%s\",\"platform\":\"%s\","
          "\"own_gil_interpreters\":2,\"native_workers\":2,\"builtin_bridge\":true,"
          "\"wrong_thread_rejected\":true,\"live_finalize_rejected\":true,"
          "\"live_thread_destroy_rejected\":true,"
          "\"exception_recovery\":true,\"utf8_and_nul_results\":true,\"one_shot_lifetime\":true,\"finalized\":true}\n",
          PY_VERSION, Py_GetPlatform());
    fclose(report);
    puts("EXTERALESS_ENGINE_PROBE_OK");
    return 0;
}

#ifdef EXL_ENGINE_PROBE_MAIN
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fputs("usage: engine-probe report.json [python-home]\n", stderr); return 2; }
    return EXLRunEngineProbe(argc == 3 ? argv[2] : NULL, NULL, NULL, NULL, argv[1]);
}
#endif
