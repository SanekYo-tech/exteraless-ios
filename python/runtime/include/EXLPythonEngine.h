#ifndef EXL_PYTHON_ENGINE_H
#define EXL_PYTHON_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* All strings are UTF-8. Input pointers are borrowed for the duration of the
 * call. Output buffers are owned by the caller and must be freed using
 * EXLPythonBufferFree (including on failure). count excludes the trailing NUL;
 * a Python result may itself contain embedded NUL bytes. */
typedef struct {
    char *bytes;
    size_t count;
} EXLPythonBuffer;

typedef struct {
    const char *program_name;
    const char *home;
    const char *executable;
    const char *const *module_search_paths;
    size_t module_search_path_count;
    int write_bytecode;
    int install_signal_handlers;
} EXLPythonProcessConfiguration;

typedef struct {
    int use_main_obmalloc;
    int allow_fork;
    int allow_exec;
    int allow_threads;
    int allow_daemon_threads;
    int check_multi_interp_extensions;
    int own_gil;
} EXLPythonInterpreterConfiguration;

/* Process lifetime is one-shot. Initialize and Finalize must run on the SAME
 * native control thread. Both return with no Python thread state attached and
 * no GIL held. Finalize refuses while any interpreter is alive or being
 * created; abandoned interpreters therefore prevent finalization as well.
 * The embedding owns CPython exclusively; an existing runtime is rejected. */
int EXLPythonInitialize(const EXLPythonProcessConfiguration *configuration,
                        EXLPythonBuffer *error);
int EXLPythonFinalize(EXLPythonBuffer *error);
int EXLPythonIsInitialized(void);
const char *EXLPythonVersion(void);

/* Create, RunScript and Destroy must be called from native code with NO GIL
 * held. Each interpreter is confined to its creating native worker thread.
 * The returned positive ID is an opaque process-local token, not a pointer.
 * Invalid IDs, wrong-thread calls and reentrant execution fail before touching
 * Python state. An idle interpreter has its GIL released. */
int EXLPythonCreateInterpreter(const EXLPythonInterpreterConfiguration *configuration,
                               int64_t *reference, EXLPythonBuffer *error);
/* Refuses live additional Python threads, preserving the interpreter detached
 * so its owner can arrange cooperative completion or mark it abandoned. */
int EXLPythonDestroyInterpreter(int64_t reference, EXLPythonBuffer *error);

/* Expressions are evaluated once; str results are returned verbatim, other
 * results use repr(). A statement suite executes once and returns "None".
 * Syntax is classified by compilation, never by catching an execution error.
 * Exceptions (including SystemExit) are returned, not printed or process-exited.
 * source_length excludes the terminator; embedded NUL source is rejected. */
int EXLPythonRunScript(int64_t reference, const char *source, size_t source_length,
                       EXLPythonBuffer *result, EXLPythonBuffer *error);
void EXLPythonBufferFree(EXLPythonBuffer *buffer);

#ifdef __cplusplus
}
#endif
#endif
