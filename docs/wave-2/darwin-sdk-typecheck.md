# Darwin SDK typecheck — 43786995069 / 5fa35f34

The independent-stage Mac run found two shared compiler causes in addition to
the separately diagnosed listener readiness failure:

- `PluginElyxDeveloperFiles`: value lookup of `kevent` denotes the imported C
  function, while `Darwin.kevent` identifies its record. Construction and arrays
  now explicitly use the record; syscalls use the function. The kqueue filters,
  zero-time polling, namespace revocation and descriptor cleanup are unchanged.
- `PluginUILifecycle.delivery`: a ternary combining a closure literal and the
  captured `@Sendable` permission predicate triggered the compiler's diagnostic
  failure. Explicit branches preserve the unconditional closed-notification
  cleanup and the original predicate for every effect-bearing callback.

The first cause blocked the candidate, FD, ingress, mode and full Host builds.
The second blocked the standalone UI model fixture. A fresh Apple run must verify
these corrections; previous Linux results do not exercise Darwin kqueue.

A new `plugin-ui-darwin-compiler-postimage.json` admits the callback-expression
correction and its selected verifier. The preceding final-cohort manifest is
preserved byte-for-byte. All13 selected files and3 shared composition regions
pass the existing source checks; the component inventory has complete sparse
coverage. Native execution remains pending.
