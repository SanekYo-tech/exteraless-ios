# Direct hook registration and CORE-API-F02

**Direct-facade ledger fix applied and exercised. CORE-API-F02's native send
ordering is staged for the coordinator, not applied to Host or `__init__.py`.**

Findings: `module-routes/plugins.md:60–69` and `sdk-symbols/core-api.md:148–168`.
Original contracts: `PluginsController.java:1698–1799,1962–1987,2280–2299` and
`python/sdk/base_plugin.py:686–728`.

## Applied source delta

- `_platform.py`: eight added lines, confined to the four existing
  `addRequestHook`, `removeRequestHook`, `addSendMessageHook`, and
  `removeSendMessageHook` bodies. Each retains `check_plugin` and delegates to
  the new `_hook_registrations.py` helper.
- The helper resolves the active SDK `PluginRecord.instance` and updates that
  instance's original `_exteraless_request_hooks` list **in place**. BasePlugin's
  bookkeeping-before-delegation and direct Java calls converge on this ledger.
  There is no additional dispatch list or target cache.
- Request registration coalesces each name/mode and shares the maximum priority
  across exact/substring modes of the same name, as Android's `priorityKey` does.
  Removal drops both modes and all priorities for that literal key; re-add can
  start at a lower/negative priority. Canonical names and Android aliases retain
  the existing schema matching. Update and Updates registrations use the original
  `addRequestHook` API. `all` retains its original literal-name meaning.
- Send registration sets the original Boolean plus
  `_exteraless_send_message_priority`. The latest registration wins, including a
  lower priority. Both removal routes clear registration and its priority.
  `send_priority` returns `None` when unregistered and validates Int32 metadata
  without invoking any SDK callback.
- Owner-worker checks, the configured id, active SDK generation and C's immutable
  interpreter id are checked before direct mutation. The helper never writes an
  owner token. Stale leased callbacks retain the existing generation rejection.
  Unregister during `on_plugin_unload` is idempotent: the SDK has already popped
  its record, and the existing cleanup owns the retired ledger.

The concurrent developer owner's `_developer.install(self)` insertion is present
in the composite `_platform.py` file. This delta changes only the four hook bodies.

## Native interest and coordinator handoff

The current interest path is:

1. Original SDK `_handled_hooks` reports **method overrides** after load
   (`plugin_loader.py:2467–2488,2753–2755`). It does not snapshot registered names.
2. `PluginRuntimeScript.applyLoadResult` copies these flags into `Plugin`.
   `PluginHost.State.recomputeGate` combines them with loaded/enabled/current
   state and `messages.read` / `messages.send` permissions.
3. `ExteralessPluginRuntime.refreshSubscriptions` publishes those subscriber
   kinds to the native routers. Core's request/update seams read these gates.
4. TL transformations already query `hook_priority_json` for each event and
   recheck the ledger in `dispatch_json`; therefore late direct add/removal takes
   effect on the next matching dispatch with the same loaded instance.

Send dispatch currently lacks step 4's priority query. Apply the exact,
**PATCHCOORONLY** file `sdk-direct-hooks-coordinator.patch` alongside the helper:

- `__init__.py`: three lines in `hook_priority_json` export validated send
  priority, or `null` for inactive/unregistered state. TL matching and loader/
  archive functions have no hunk.
- `PluginHost.swift`: `canInvokeSend` plus the send-chain priority stage. Queries
  run via the existing bounded owner-worker `invokePlugin`, with the captured
  interpreter handle, send origin and batch retention. Output is bounded to
  128 UTF-8 bytes and decoded as an exact Int32; Boolean/string/fraction/overflow
  metadata is rejected. One query per candidate precedes sorting by descending
  priority, then ascending plugin id for ties.
- The same generation/permission predicate runs before admission, on the actual
  worker, after the query, before the callback and after its result. Retired or
  unregistered targets are skipped. A metadata exception/invalid result skips
  that target without resetting native params or another plugin's result, and
  without treating it as a callback failure. Existing timeout/watchdog and batch
  cancellation handling continue to apply.
- The existing sparse-patch application, `CANCEL`, `MODIFY_FINAL`, native origin
  and read-credit ownership remain in their current chain. Priority inspection
  allocates no SDK callback handles. It uses the existing per-call and batch
  deadlines; there is no main-thread sleep/wait.
- Two one-line fake-engine fixture updates return an explicit priority `0` for
  their registered send hooks, keeping their existing ownership/cancellation
  assertions active under the new query contract.

`git apply --check docs/wave-2/sdk-direct-hooks-coordinator.patch` passed against
the concurrent working tree. In-memory patch validation confirmed that only
`hook_priority_json` changes in the Python adapter. Swift lexical checks passed;
they are not compilation evidence.

## Regression evidence

Fresh bounded workers use the configured original SDK and the owned source
`tools/compat/tests/fixtures/sdk_direct_hooks/owner.plugin` through public
`jclass("app.exteraless.plugins.PythonBridge")` and unchanged BasePlugin methods.
Each transport observes **25 admitted callbacks, each invoked once**, and checks:

- late direct add after a negative priority query/dispatch; normal BasePlugin
  registration and repeated calls; direct removal after Base registration;
- overlapping names, shared exact/substring key priority, negative/re-added
  priorities and all seven native Updates constructors;
- send priorities `100` then `-100`, idempotence, direct/Base removal and malformed
  stored send-priority metadata;
- foreign add/removal while valid hooks are registered, wrong worker, immutable
  C id/epoch, direct unregister during unload and a stale callback against the
  next SDK generation;
- original borrowed TL metadata/default snapshots and zero handles after unload.

The only reload in this fixture tests retirement after all late-registration
scenarios have completed on the original instance.

| Interpreter | Focused checks | Wall time | C dispatcher calls |
| --- | --- | --- | --- |
| CPython 3.12.10 | **6 PASS** | 3.18 s | 368 |
| CPython 3.14.8 | **6 PASS** | 3.62 s | 637 |

Each six-check run includes the new unit/C workers, existing SDK lifecycle-hook
and TL-hook cases, and both original owned native-TL Python fixtures. Child
timeout is 20 seconds; the outer runs were bounded to 30 seconds.

C mode uses the real `BridgeBackend`, dispatcher ABI, owner binding and handle
operations. Only desktop native services are recorders. The recorder uses ctypes
and therefore has fixture-only `native` permission; `hooks`/Xposed is denied in
both new transports. Existing source/header/binary pins were verified:

```text
f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a python/bridge/_exteraless_bridge.c
6ecab9d92438e62bd3f0d7218f9646b78f9e3f764cc5d4e9f9e5a78b85b6166d python/runtime/include/EXLPythonBridge.h
e930d67050661a4a5486cd60e046c3c584221296fdaf64223fd67cc25b5df407 sdk-tl-self-bridge-py312/_exteraless_bridge.cp312-win_amd64.pyd
aa40823e5de9608f36c3a7c25dfdc261f819da37adc258d818b13b35555a63e8 sdk-tl-self-bridge-py314/_exteraless_bridge.cp314-win_amd64.pyd
```

The binary directories are under `C:/Users/sasha/AppData/Local/Temp/opencode`.
Use `EXTERALESS_DIRECT_HOOK_C_BRIDGE` for the matching extension when running
`test_sdk_direct_hooks.py`.

### Prepared native checks

`swift/PluginHost/Tests/PluginHostTests/PluginSendHookPriorityTests.swift` adds eight
fake-engine tests targeting the actual Host send chain: two-plugin `100/-100`
ordering and sparse modifications, cancellation/finality, stable ties and late
registration/removal, query failures/invalid metadata preserving native original
or the other result, generation retirement during query, permission revocation,
retirement after callback entry, and cancellation retaining the read credit until
the worker exits. Fake-engine gates and waits are bounded (5 s / 2 s).

**Native compilation/execution is pending**: `swiftc` is unavailable locally and
the coordinator-only production hunks are not applied. After their integration
and the normal separate Host compilation, run this test class with a hard
30-second runtime bound, e.g. from `swift/PluginHost`:

```sh
python3 -c 'import subprocess; raise SystemExit(subprocess.run(["swift", "test", "--skip-build", "--filter", "PluginSendHookPriorityTests"], timeout=30).returncode)'
```

Supplied Mac `20e16` GREEN (`680 Core`, three children, C219) is independent
baseline evidence. This handoff supplies no new app/graph execution receipt.
No CI query/dispatch, commit, external plugin, account or live RPC was used.

## Frozen source delta

At freeze HEAD `00bf334468faa38147d3c54b33e065f60d869744`, raw SHA-256:

```text
768e9670f27a8edda9987e8792788125f590d0d8f5fcca4ffa3caa4b442352bf docs/wave-2/sdk-direct-hooks-coordinator.patch
888affeff0b233b41fda8f12f91c828fd206e61ea93146a95db7e2e981ee654f python/exteraless_runtime/_hook_registrations.py
2f8cd093c2aeacc64fb56b20e42ec7d09ef226ed2f81e90ddf8dbfa9d206d9b1 python/exteraless_runtime/_platform.py
e2ade96c9387c42cf26213caead612271615f8a5a1688a88ca02f0275bf0cced swift/PluginHost/Tests/PluginHostTests/PluginSendHookPriorityTests.swift
a0e4ce2a37998cd8286fcf0ceddd8ff6821cff0b6df98b473c393b938a219867 tools/compat/tests/fixtures/sdk_direct_hooks/owner.plugin
4d16a7fd506f41e3f82f562e7a493fdf19f471426eee75a123082dd91c2b4dc0 tools/compat/tests/test_sdk_direct_hooks.py
```

Six-file corpus: `0d83e51a2a397545fbf3b1a4a92d083cdb4d923a5213313b1ddfae523cb15625`
(SHA-256 of sorted `path + NUL + raw_sha256_hex + LF` records above).
The independent four-method `_platform.py` scope hash is
`f3e851fc63ad8f5a8ed11c763e7e53f53d36c721061c4cd0c9db2521ad4ab214`:
concatenate complete method source spans, including indentation and final LF,
sorted by method name. It is independent of concurrent `install` edits.

Build-input delta: one new shipping Python helper, the modified four method
bodies, and the staged existing Host/adapter source changes. The existing Mac
driver's recursive Python source inventory includes the helper automatically
(`check_swift_plugin_embedding.py:380–381`). The new Swift test is a new Host
test input; its two existing fake-engine input updates are in the coordinator
patch. Component totals and historical inventories are not reissued here.

## APPLIED — coordinator receipt and read-only postimage check

Coordinator reported application of the complete
`sdk-direct-hooks-coordinator.patch`: Host, Python priority query and the two
existing Host fixtures. Read-only inspection at HEAD
`897e3106618ab62a779ed26cfc3661115c0caff9` confirmed **all six postimage hunks in
four files match the frozen patch exactly**. This APPLIED receipt supersedes the
earlier staged-state statements; the earlier hashes and execution receipts remain
historical.

### Actual chain and eight new test assumptions

- Host sends exactly `hook_priority_json("on_send_message_hook", "", "")`;
  the new fixture decoder expects those same arguments. The applied Python branch
  reads the existing validated send ledger, returning `null` for inactive or
  unregistered state. It invokes no SDK hook callback.
- Both query and callback keep `expectedHandle: target.handle`, the same send
  root, `tlOrigin` and `batch`. Their predicates reach the actual owner worker via
  `invokePlugin`; post-await checks precede insertion into the sorted targets or
  publication of a replacement. The current target lookup rejects unloading,
  replaced, unloaded and not-responding generations.
- Priority output remains limited to 128 bytes and an exact Int32. The chain
  skips `null`/invalid/failed metadata, sorts descending with ascending-id ties,
  and preserves sparse-patch merging and the existing terminal strategies.

`PluginSendHookPriorityTests.swift` still matches its frozen SHA-256
`e2ade96c9387c42cf26213caead612271615f8a5a1688a88ca02f0275bf0cced` and contains the
same eight test methods. Their source assumptions align with the applied chain:

| New test scenario | Checked source assumption |
| --- | --- |
| Descending priority / sparse MODIFY then FINAL | `beta=100` precedes `alpha=-100`; one callback per target; full merged params reach alpha. |
| CANCEL / MODIFY_FINAL | Either terminal decision prevents the lower-priority callback. |
| Late registration/removal / equal-priority ties | Every send queries fresh metadata; `null` skips; alphabetical ties hold even with reverse installation order. |
| Failed/malformed query | Ordinary query failures skip that owner without retiring it or resetting native/or-other-plugin results. |
| Retirement during query | The captured old handle cannot enter the callback or resolve to the replacement generation. |
| Permission revoked after query | Current send permission is checked again before callback admission. |
| Retirement after callback entry | The post-await predicate rejects the retired callback's replacement. |
| Cancellation during query | The waiter receives cancellation while `PluginInvocationRetention` keeps the running query's read credit until worker completion. |

The fixture explicitly installs source `.plugin` files with supplied metadata,
so its `1/2` interpreter references do not acquire an archive-inspection worker.
Its engine checks owner-thread identity; its send permissions are explicitly
granted after leaving unsafe mode. Waits remain bounded. This is **source
validation**, not a new compilation or execution receipt; no SDK cohort, native
tests or CI were run for this follow-up.

### Two further existing fixture responses — PATCHCOORONLY

The two Host fixture responses from the original patch are present. A targeted
scan of the other actual Host send callers found two additional deterministic
fixture omissions:

1. `telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift`:
   `TLGuardScenario.script` has no priority response and `TLGuardEngine` falls back
   to `"null"`. Thus `testRealProviderTicketRevokesOnCancelledParentSend` skips
   both callbacks: alpha creates no provider ticket and beta never fulfills its
   worker-entry expectation.
2. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift`:
   the `batchConsumer(outcome: "cancel")` engine also falls back to `"null"` before
   the callback-only `ui_followup` guard. Its one-second beta admission wait then
   expires before alpha can create the retained UI effect.

Give these already-registered fake send hooks an explicit priority `0`, restoring
their original alpha/beta order. The exact pending hunks preserve every callback,
cancellation, ticket, effect and credit assertion:

```diff
--- a/telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift
+++ b/telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift
@@ -47,6 +47,7 @@
                 return "{\"metadata\":{\"id\":\"\(name)\"},\"handles\":{\"app_event\":true,\"send_message\":true},\"has_settings\":false}"
             }
         }
+        if source.hasPrefix("_exteraless_runtime.hook_priority_json("), source.contains("on_send_message_hook") { return "0" }
         let trigger = self.sendEvent ? source.contains("on_send_message_hook") : source.contains("tl_f01_case")
         guard source.hasPrefix("_exteraless_runtime.dispatch_json("), trigger else { return nil }
         switch self.names.with({ $0[reference.raw] }) {
--- a/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift
+++ b/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift
@@ -491,6 +491,7 @@
                 let id = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
                 return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":true,\"send_message\":true},\"has_settings\":false}"
             }
+            if source.hasPrefix("_exteraless_runtime.hook_priority_json("), source.contains("on_send_message_hook") { return "0" }
             guard source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("ui_followup") else { return nil }
             if reference.raw == 1 {
                 guard let host = hostReference.get(), let owner = host.callbackOwner(id: "alpha") else { throw HNSFixtureError("Missing actual A owner") }
```

The queue-only ingress/timeout and protocol-builder tests bypass this Host query
stage. `ObservedNativeEngine` forwards its sources to the real CPython engine;
it needs no canned priority response.

### Applied source projection

SHA-256 of the named source spans: UTF-8, LF endings, original indentation and
one final LF; trailing blank lines are excluded. The send span runs from its
`case .sendMessage` through `return .sendMessage(result)` within `handleEvent`.
These projections remain stable when unrelated Host/loader sections move.

```text
0d12441b51cb85b5f429d9dfffc687cc485fdf203386e4edb7e2e9a403526cf2 python/exteraless_runtime/__init__.py#hook_priority_json
12b46a69acc4d71fb05845fdd4f5c6afafaf32cd69e1dda49c6e768959db472b swift/PluginHost/Sources/PluginHost/PluginHost.swift#canInvokeSend
6c231a514e3736dbf85f2af8e166a7268e1580990b6d8d8867e1d0384de7d8d6 swift/PluginHost/Sources/PluginHost/PluginHost.swift#handleEvent.sendMessage
```

Projection corpus:
`2b02b9f5700ad0bf501ea18c3bc80931ace9c41e41fb27df3c63aee23fb9032f`
(SHA-256 of sorted `path#scope + NUL + span_sha256_hex + LF` records).

Coordinator applied both additional fixture-priority responses above. Their
provider-ticket, retained-effect, cancellation and credit assertions are intact;
the newly composed cohort still awaits its Host/native execution.
