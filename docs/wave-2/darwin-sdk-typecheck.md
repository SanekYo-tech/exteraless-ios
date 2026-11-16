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

## Follow-up: 43788170016 / d296e456

The Darwin record/syscall and UI callback fixes compiled. The next Host/test
build reached four region-isolation checker failures in
`PluginSendHookPriorityTests`: each Task read `Self.native` inside its body.
Each test now evaluates that static String into a local immutable value before
creating the Task. The held worker barriers, cancellation/retirement schedules,
deadlines and all assertions are retained; no production source is changed.
The same run predates the independently passed listener fix78f37532.

Independent stages in43788170016 passed the native candidate fixture, all7
ingress tests, all4 Mode ABA tests, the standalone UI model fixture, TL/Java
fixtures and Core/Hooks. Host test compilation still failed on the four captures,
so no full Host, HNS or five-child runtime pass is inferred from those successes.

## Native execution follow-up: 43789795179 / 1df7fda0

Listener, all47 FD/activation/transaction cases,7 ingress and4 Mode ABA tests
passed on Darwin. The complete Host suite compiled and executed; one older archive
descriptor test did not trigger its swap hook because it compared the raw `/var`
fixture path against the descriptor walk's `/private/var` path. Its three failures
were the absent expected throw, false `swapped` flag and absent saved tree.

The expected hook path is now canonicalized once, while the newly created fixture
is still trusted and before the adversarial swap hook is installed. No callback
resolves a replaced link. The real parent swap, expected refusal and both-tree
preservation assertions remain required. Production archive code is unchanged.
