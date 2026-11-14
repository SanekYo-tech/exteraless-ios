#ifndef EXL_ENGINE_PROBE_H
#define EXL_ENGINE_PROBE_H

/* One-shot native engine test, two short-lived worker threads, no plugins.
 * Call only in a fresh process; the caller supplies an external hard timeout. */
int EXLRunEngineProbe(const char *home, const char *stdlib_path,
                     const char *dynload_path, const char *executable_path,
                     const char *report_path);

#endif
