#ifndef EXL_RUNTIME_PROBE_H
#define EXL_RUNTIME_PROBE_H

/* A bounded, one-shot embedding probe. Run on one thread in a fresh process.
 * NULL home/stdlib/dynload uses the host Python installation for local tests. */
int EXLRunRuntimeProbe(const char *home, const char *stdlib_path,
                      const char *dynload_path, const char *report_path);

#endif
