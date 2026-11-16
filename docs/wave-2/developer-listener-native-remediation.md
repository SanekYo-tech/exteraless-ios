# Native developer listener — Darwin failure and remediation

Date: **2026-11-16**. Scope: `PluginDeveloperServer.swift`,
`NativeDeveloperServerProbe.swift`, and `test_sdk_developer_native.py`.

## Observed cause

The supplied macOS run **43786148988 / a823e619** compiled the listener fixture,
then failed its two-second readiness assertion. Its generic message did not
contain the listener's state, so it did not establish a bind collision.

The authorized, isolated diagnostic run
[43787335670](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43787335670)
at commit `3504c3d103ef038d69854500cfabcd146162eb2d` compiled in **8.578 s** and
recorded the actual failure:

```text
Developer server unavailable: NWError.posix(22, POSIXErrorCode(rawValue: 22))
EXIT 1
```

This is **EINVAL**, thrown synchronously during `NWListener` creation. The source
provided an address and port in `NWParameters.requiredLocalEndpoint` and then
specified the port again with `NWListener(using:on:)`. It had not reached listener
startup/readiness. The diagnostic run used the actual Network implementation and
the same four shipping UI sources; it did not probe any other process on the port.

## Implementation

- Construct the listener with **`NWListener(using: parameters)`** after setting
  `requiredLocalEndpoint` to **`127.0.0.1:42690`**. The required endpoint supplies
  both address and port. The ready handler additionally checks the actual bound
  port before publishing the private authentication token.
- Diagnostics contain bounded native error domain/code and description. The
  fixture reports the current **`snapshot.status`** on state changes and timeout;
  it never formats a snapshot or logs its token. Each native error is capped at
  768 UTF-8 bytes. The SDK's additional Network error cases use a bounded default
  diagnostic rather than an incomplete enum switch.
- Network may report an owned bind collision as **`.waiting(.posix(.EADDRINUSE))`**.
  Retire/cancel that attempt and release its session reservation so a subsequent
  `start` can retry after the port is released. Other transient waiting states
  retain their normal pending behavior. Diagnostics retain the actual waiting
  state and error code.
- Native authentication, synchronous session revocation, epoch guards, and the
  post-handler committed-outcome receipt path remain intact.

## Actual fixture assertions

The same real listener/protocol fixture now requires:

1. An actual owned token-write error reports `NSCocoaErrorDomain`, has no ready
   token, and never enters the request handler.
2. First-listener readiness on the required loopback port; unauthenticated ping
   and original correlation-ID framing.
3. Wrong-token rejection without handler entry.
4. A cancelled handler's known committed publication outcome survives the wire.
5. A second listener collides with the **first owned listener's port** and reports
   the actual `EADDRINUSE` code, rather than accepting an arbitrary startup error.
6. First-session synchronous retirement, retry after release, a fresh token,
   rejection of the retired token, and acceptance of the current token.
7. Replacement-session retirement and cleanup of the owned token files.

The fixture connects only after its own listener publishes readiness. No existing
service is authenticated/probed, and no unrelated process is killed.

## Verification isolation and bounds

The diagnostic and observed-cause follow-up use private branch
`verify/native-developer-listener-a823-56f296f00a`, based on
`a823e6191a5e7e9770df261529237b3663cd40ad`. Tree creation uses a private
`GIT_INDEX_FILE` and Git plumbing. Only the three owned source paths and a
branch-owned `.github/workflows/python-framework.yml` are included in its delta.
The shared main workflow, main HEAD and main index are not edited by this work.

Each dispatch has **one `macos-26` job**, using
`/Applications/Xcode_26.6.app/Contents/Developer`, sparse-checking out only the four
UI Swift sources, fixture, driver and workflow. It invokes the Python CLI directly:

```text
python3 -B tools/compat/tests/test_sdk_developer_native.py OWNED_OUTPUT
```

There is no pip, runtime dependency staging, CPython/framework download, simulator,
Host/FD/Mode test rerun, or sibling-job polling/cancellation. Compilation is capped
at **120 s**, the executable at **10 s**, and individual readiness waits remain
**2 s**. The fixture reports controlled failures instead of a top-level Swift trap.

The driver always retains compile/execution logs, six exact source copies and
their SHA-256 pins under `evidence/`. The workflow adds its own source/pin receipt
and uploads this evidence even on failure. Token-bearing runtime directories are
outside the uploaded evidence tree. API credentials and the configured origin URI
are never printed.

## Final execution and source pins

**PASS — actual Darwin execution:**
[43787862250](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43787862250),
commit **`bbc548175e4ad622d3fd329403cc364fa873a620`**. Compilation completed in
**9.864 s**, with no compiler diagnostics; execution completed in **0.337 s**,
exit **0**, within the unchanged 120/10-second limits. The success marker follows
all readiness, authentication, retry, revocation, cleanup and committed-outcome
assertions listed above.

Observed native events:

```text
Developer server unavailable: NSCocoaErrorDomain(512): [owned token-write error]
Listening on 127.0.0.1:42690
Developer server failed: NWError.posix(48, ... Address already in use)
Listening on 127.0.0.1:42690
first=Stopped; second=Stopped
SDK_DEVELOPER_NATIVE_OK storage_refusal_ready_owned_bind_error_retry_auth_session_revocation_committed_receipt
EXIT 0
```

The controlled collision was delivered as `.failed(.posix(.EADDRINUSE))` on this
runner. The `.waiting(.posix(.EADDRINUSE))` cancellation/retry branch is source-
verified only; it was not emitted by this execution. Acceptance here covers
**Darwin/macOS Network**. Native iOS execution was not performed.

Downloaded evidence archive SHA-256:

| Run | Artifact | SHA-256 |
|---|---|---|
| Diagnostic 43787335670 | `native-developer-listener-43787335670` | `94c43415941017ee097fb953fa00c1f2289412f89ff7eaf0d93309207da1a914` |
| Passing 43787862250 | `native-developer-listener-43787862250` | `a99e47387f840ff9865abf25f4918c487c6a35ab473b049008f10661b53eadc2` |

Local passing evidence is retained under
`C:\Users\sasha\AppData\Local\Temp\opencode\developer-listener-a823-7f10b50e\follow-up-artifact`:
`compile.log`, `execute.log`, `native-listener.json`, `workflow-inputs.json`, and
the exact source copies. The workflow source SHA-256 is
`a8b8e084c29bae9b584cd3097535477dcd8650388e8dfd56f2dcd2bb63047a7d`.

### Final main-ready source postimages

These are the exact raw bytes compiled and executed in the passing run. The three
owned paths are the main handoff; the verification workflow remains branch-owned.

| File | SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperServer.swift` | `3527975d1e559c68b1a03a3353907640da3e4ff5d46564b9d69a0a170dad8a2c` |
| `tools/compat/tests/fixtures/sdk_developer/NativeDeveloperServerProbe.swift` | `68de391840829effd6ba48ad0e6d3d11f102507da2e133b7bd4a212498333cd8` |
| `tools/compat/tests/test_sdk_developer_native.py` | `865e4852ac8bbaab12915862bac9fea7647ae3b39cef4b08d91fcbc95cadc045` |

All six compiled/driver input hashes are also recorded in `native-listener.json`;
the workflow-inclusive seven-input set is in `workflow-inputs.json`. Main HEAD,
index and shared-workflow guards remained unchanged around both isolated Git
operations and on completion. Only the authorized diagnostic run and its observed-
cause follow-up were dispatched. No main commit/push or sibling CI operation was
performed. Local checks additionally verified Python AST, retained success/failure
logs, the helper's existing two-argument calling convention, and scoped whitespace.

**Source freeze:** the three postimages above are the final listener handoff.
