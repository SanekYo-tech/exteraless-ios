# SDK symbol remediation — independent source closure

**Eight listed counterexamples are source-closed. ELYX-P2-02 has its Python
argument mismatch fixed, but remains partial at the production native command
ingress (P2).** All three coordinator handoffs are applied. This is a source
closure, not nine execution passes or verification of the 925-symbol SDK.

- Review date: **2026-11-15**; observed HEAD:
  **`897e3106618ab62a779ed26cfc3661115c0caff9`**, with concurrent uncommitted work.
- Read-time source pins: **19:52:32 UTC**; shared-file pins: **19:54:05 UTC**.
  The hashes below identify the reviewed working tree rather than attributing
  these changes to HEAD.
- Authored file: this document only. Original findings/remediation reports are
  retained and pinned below. **36/36 SDK Python files match their vendored
  Android originals byte-for-byte.**
- Scope: `sdk-symbols/core-api.md` F01–F05, the direct-hook finding in
  `module-routes/plugins.md`, Elyx gen/dev witnesses, and the utilities daemon
  witness. The separately owned Elyx archive P1 and manager Custom/alias,
  trust, UI and settings-search work receive no verdict here.

## Verdict ledger

Original report links retain their original snapshot line numbers. Implementation
anchors below refer to this review's working-tree pins.

| Counterexample / original report | Earlier root cause and witness | Current disposition |
|---|---|---|
| **CORE-API-F01**, [core-api.md:124–146](../sdk-symbols/core-api.md#core-api-f01--accountclient-edit-default-loses-omission) | `AccountClient(2).edit_message(target, text="replacement")` forwarded default `False`, unlike the module helper's omitted spoiler. Native text edits could fail or a media spoiler could be cleared. | **Source-closed.** The installed AccountClient override forwards the same omission sentinel; explicit False remains explicit. Native edit validation remains on the actual route. |
| **CORE-API-F02**, [core-api.md:148–168](../sdk-symbols/core-api.md#core-api-f02--send-hook-priority-is-discarded) | Registrations at `100` and `-100` retained identical Boolean state; Host never queried send priority. | **Source-closed.** Shared registration retains the latest send priority; the actual Host send branch queries and sorts it, with captured-owner guards. New native execution remains pending. |
| **CORE-API-F03**, [core-api.md:170–189](../sdk-symbols/core-api.md#core-api-f03--missing-class-produces-a-positive-proxy) | `find_class("org.telegram.messenger.CoreApiMissingClass")` returned a generic proxy with **zero** backend existence calls. | **Source-closed for that witness.** Production installation now requires the actual backend's strict positive existence result for an unregistered JavaClass. This remains manifest existence, not proof of every native member. |
| **CORE-API-F04**, [core-api.md:191–205](../sdk-symbols/core-api.md#core-api-f04--request-callback-exception-containment-changed) | A user `ValueError` escaped `RequestCallback.run` / request completion instead of being contained by `safe_call`. | **Source-closed.** Decoding precedes the user guard; both callback shapes reach the installed Exception-only `safe_call`. Terminal/FIFO ownership remains separate. |
| **CORE-API-F05**, [core-api.md:207–230](../sdk-symbols/core-api.md#core-api-f05--cancellation-crosses-named-queues) | Cancelling the shared callback through STAGE_QUEUE also selected GLOBAL_QUEUE; public `postRunnable` exposed an internal string id. | **Source-closed.** Selection includes the logical queue; public admission is Bool. False/failed native cancellation retains the selected lease for its actual terminal winner. |
| **Direct-hook P2**, [plugins.md:60–69](../module-routes/plugins.md#focused-counterexamples) | Public `PythonBridge.addRequestHook` only checked ownership; direct add was inert and direct remove did not remove BasePlugin registration. | **Source-closed.** Both public routes mutate the same live instance ledger in place; the existing production interest/dispatch path consumes it without reload. |
| **ELYX-P2-01**, [elyx.md:253–278](../sdk-symbols/elyx.md#elyx-p2-01-generic-gengen2-constructor-mismatch) | Original `gen(I,"run")(fn)` / `gen2(I,run=fn)()` called a generic base initializer requiring `fqcn, backend`. | **Source-closed.** The generic dynamic-proxy base has a legitimate zero-argument initializer; ordinary native-value construction retains its required arguments. |
| **ELYX-P2-02**, [elyx.md:280–298](../sdk-symbols/elyx.md#elyx-p2-02-dev-server-argument-shape) | `_cmd_elyx` passed the entire request dict as the command; the original handler stringified it and returned unknown command. | **Locally closed; production route still P2.** The installed shim passes command and params separately, but the actual native listener's handler rejects `elyx_*` and `get_elyx_plugins`. |
| **utilities-P2-001**, [utilities.md:136–151](../sdk-symbols/utilities.md) | Daemon-thread construction conflicted with OWN_GIL policy; the loader set its once latch before failure, preventing retry. | **Source-closed as a native listener adaptation.** Installed start/stop use readiness and bounded native control admission; retry never enables developer mode. Native execution remains pending. |

**Remaining P1:** none identified in this bounded review. **Remaining P2:** the
native Elyx command route described below. The original core report does not
assign P1/P2 ranks to F01–F05; this document does not retroactively label them.
Pending compilation/execution is an evidence gap, not an additional reproduced
P1/P2 defect.

## Source path key

| Key | Repository path |
|---|---|
| `PY` | `python/exteraless_runtime/` |
| `SDK` | `python/sdk/` |
| `HOST` | `swift/PluginHost/Sources/PluginHost/` |
| `APP` | `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift` |
| `UI` | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/` |
| `TLUI` | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/` |
| `JAVA` | `third_party/exteraless-android/TMessagesProj/src/main/java/` |

## Production installation and authority

The joined route is present in the application, not merely in new helper tests:

1. `APP:152–179,237–264` constructs Host, installs `NativeBridgeBinding`, creates
   the real TL provider and adds **PluginDeveloperBridgeExtension** to the
   composite beside PluginConfig/UI/native services.
2. `HOST/PythonRuntime.swift:111–136` installs C `BridgeBackend` and calls
   `configure`; `PY/__init__.py:74–93` calls the actual `Platform.install`.
   `PY/_platform.py:316–337` installs logging, TL, queues and facades, then the
   developer shim and native Runtime metadata, finally `_reflection.install`.
   Developer installation itself only replaces seams and resets the latch.
3. `PY/_facades.py:19–24,87–95` registers the public PythonBridge facade, whose
   members resolve to the same Platform. Its four hook methods at
   `PY/_platform.py:177–195` retain worker/id checks and call the shared ledger.
4. `Platform.call:89–95` reaches C `py_xt_call_host:3252–3282` in
   `python/bridge/_exteraless_bridge.c`. `native_request_context:1961–2000`
   discards supplied top-level identity values and injects C's bound plugin/epoch;
   setters at `3169–3249` allow only matching repeated binds. Transport reaches
   `HOST/NativeBridgeBinding.swift:73–95` → `BridgeServices.swift:200–245`.
5. `BridgeServices` validates the owner before descriptor/provider dispatch.
   `HOST/PluginHost.swift:257–265,287–306,598–601,1273–1280` distinguishes a
   live captured callback owner from cleanup-only retiring authority. A new
   generation cannot substitute for the captured handle/token.

Runtime discovery is the real `exportedMethods` union
(`HOST/PluginBridgeExtension.swift:23–46`), with the live metadata resolver at
`PY/_platform.py:333–335` and `python/virtualjava/proxy.py:17–29`. An unknown member
does not retain a positive metadata-cache entry. The new developer operations are
zero-argument static calls; `HOST/NativeServiceWire.swift:74–103` rejects setter,
instance, keyword and incompatible argument shapes. Discovery creates no effect
or Python callback lease. A previously obtained callable still encounters the
current native provider/owner validation when invoked.

## Core counterexamples: exact post-fix consequences

### F01 — omission survives the AccountClient boundary

`SDK/client_utils.py:882–886` still contains the original False default. The late
assignment at `PY/_tl.py:599–602` is therefore essential: its bound
`account_edit_message` uses `_OMITTED` and forwards `self.account` into the same
`edit_message:579–597` used by module callers. Omission produces no `spoiler`
key; explicit False/True produce that exact Bool. Non-Bool input fails before
native submission. Caption/entity omission and an explicitly empty caption are
also distinct.

The real continuation is `native_media:475–500` → `Requests.submit:320–355` →
`TLUI/PluginTLBridgeExtension.swift:181–188,212–244` →
`PluginTLModels.swift:252–281` → `startEditMedia:376–396` →
`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLMediaEditServices.swift:72–131`.
The decoder preserves absent spoiler as nil at line 280. Core then keeps media
at lines 119–120 and retains its existing spoiler at line 101. Explicit False
still selects the deliberate reference-edit branch at lines 106–118, including
`EDIT_SPOILER_REQUIRES_MEDIA` for a text-only target. That explicit rejection is
not the old omitted-default defect. Account/permission/target validation and
native cancellation predicates still precede the effect.

### F03 — fail-soft lookup consults the real backend

The wrapper at `PY/_reflection.py:15–36` first uses the original
`SDK/hook_utils.py:34–71`, preserving alias/substitute adaptation. It unwraps
field-shaped aliases for classification, returns local/registered/schema/array
ports through their valid route, and checks worker and permission before accepting
an unregistered JavaClass. The positive condition is literally
`finder._State.backend.class_exists(fqcn) is True`; false, `1`, exceptions and
denials produce None. The original witness now requires an existence query rather
than trusting `get_class` manufacture/cache.

The terminal C implementation is `bb_class_exists:2739–2757` →
`bb_class_known:2191–2194`, a lookup in the loaded manifest class set. It does
**not** call Swift `class_exists` or certify an arbitrary declared member/provider.
Registered Python ports remain usable without inventing a generic native
constructor. The applied production install at `PY/_platform.py:336–337` closes
the earlier helper-only integration gap; the author's extra in-test installation
alone would not establish that fact.

### F04 — only the user callback is contained

`PY/_tl.py:332–343` decodes the response/error before selecting and invoking the
user function/delegate through `android_utils.safe_call`. The installed
`RequestCallback.run:417–420` uses the same helper within its account scope.
`PY/_logging.py:15–29` catches **Exception**, logs best-effort and returns None;
KeyboardInterrupt/BaseException still propagates. An already wrapped delegate
contains its own user error, so the outer guard does not duplicate that log.
Both paths discard user return values, preventing an ignored arbitrary object
from becoming another result handle.

Schema errors, wrong-worker/closed-generation entry, native admission and
cancellation errors remain outside this user guard. `PY/_callbacks.py:24–38`
closes terminal leases in `finally`; `close:50–64` leaves native-owned C handles
to FIFO release. The actual TL completion path is
`TLUI/PluginTLBridgeExtension.swift:420–470,515–520` →
`HOST/PluginCallbackDispatcher.swift:117–158,190–208` → Host's captured-owner
invoke/release at `PluginHost.swift:1329–1367` →
`PY/__init__.py:122–129,388–423`. Callback completion and handle release are
ordered even when decoding or user control-flow raises.

### F05 — logical queue selection and cancellation ownership

`PY/_scheduling.py:10–16,24–84` stores `(lease, callback, logical_queue)` and
passes `self.name` from `OwnerQueue.cancelRunnable`. Only matching queue entries
can be selected, whether addressed by callable identity or an internal task id.
The exact selected lease is checked again before cancellation/close. The public
`postRunnable` returns **True only after successful native admission**; the
internal scheduler retains the actual string id. Rejected admission still raises.

The native route remains
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:130–159,250–261`
→ `HOST/NativeServiceCleanup.swift:29–36` →
`NativeServiceScheduler.swift:60–75`. Cleanup compares the stored plugin/epoch,
including during retiring unload, rather than reacquiring a replacement owner.

- **False:** Python leaves the task/lease open. Native cancellation has no matching
  pending entry; an already-fired entry can still deliver its terminal callback.
- **Malformed/throwing:** the Python call fails and retains the lease.
- **True:** only the selected lease closes; native owns its queued C release.

Native fire removes due entries and terminally sends them at scheduler lines
93–105. `HOST/NativeServiceCallback.swift:197–215,246–278` preserves admitted
terminal delivery entitlement and enqueues release once. Failed admission uses
`reject`, while Python rolls back its handle ownership. The HNS fixture's updated
internal-id lookup preserves a real cancellation token; it does not use the new
public Bool as an invented native id.

## Direct hooks and send priority

### One ledger through both original entry points

Original contracts are `JAVA/app/exteraless/plugins/PythonBridge.java:64–77`,
`PluginsController.java:1698–1799,1962–1988`, and
`SDK/base_plugin.py:686–728`. The applied helper
`PY/_hook_registrations.py:10–86` resolves the active `PluginRecord.instance`.
BasePlugin's pre-delegation bookkeeping and direct facade calls converge on that
instance's **same list**, mutated with slice assignment. Request registrations
share a maximum priority across exact/substring modes of the same literal name;
removal drops both modes so re-add can start lower. Send uses latest registration,
including `100` → `-100`, and removal clears registration/priority.

Production interest does not snapshot registered names:
`SDK/extera_utils/plugin_loader.py:2467–2489` reports method overrides;
`HOST/PluginRuntimeProtocol.swift:51–79` stores those flags;
`PluginHost.swift:235–247` publishes permitted loaded interest;
`APP:1116–1121,1143–1154` installs TL transforms and router subscriptions.
Fresh query/dispatch reads at `PY/__init__.py:254–286,342–351` consume late
registration/removal. Thus the original direct-add/direct-remove witness is
closed in the existing consumer, not by a second unused registration cache.

Foreign id/wrong worker is rejected at the facade; immutable C id, active SDK
generation and matching instance are checked before mutation. The SDK pops its
record before unload (`plugin_loader.py:2824–2843`), so direct removals there are
idempotent; `PY/__init__.py:141–185` owns the final ledger/lease cleanup. Stale
leased callbacks are rejected before their body by `PY/_callbacks.py:24–28`.
Hook registration and priority inspection add no callback handles. Native read/send
permission admission remains authoritative even though the Python ledger itself
is bookkeeping.

### The Host now consumes send priority

`APP:1074–1102` reaches the real `host.events.preSendMessageResult`. The applied
`HOST/PluginHost.swift:1503–1508,1540–1608`:

1. Captures current subscriber handles, queries
   `hook_priority_json("on_send_message_hook", "", "")` once per eligible owner,
   and retains the same send root/origin and batch.
2. Bounds output to 128 UTF-8 bytes; null skips; the integer reader
   (`PluginServiceModels.swift:279–284`) rejects Bool/string/fraction, and
   `Int32(exactly:)` rejects overflow. Python also validates stored priority type.
3. Sorts descending priority, then ascending plugin id for ties. Each admitted
   callback receives the accumulated params. Sparse merging is the actual
   `PluginRuntimeProtocol.swift:99–112`; CANCEL and MODIFY_FINAL remain terminal.
4. Rechecks live generation, enabled/handled state and messages.send permission
   before admission, on the owner worker, after query, before callback and before
   publishing its result. `invokePlugin:1739–1789` retains the captured handle;
   retiring/replacement owners cannot supply a late replacement.

**Malformed/failed priority metadata cannot revert another result.** Its catch
at lines 1568–1574 only checks batch cancellation and logs; it neither resets
`currentParams`/`result` nor calls `recordExecutionFailure`. All priority queries
precede callbacks. An invalid owner is absent from the sorted set, so the remaining
valid owner's modification survives. Ordinary metadata failure also does not
retire that owner's unrelated leases. Existing timeout/watchdog handling still
applies to an actually stalled worker.

`HOST/PluginEventExecution.swift:111–151` keeps the batch's read credit in
`PluginInvocationRetention` through queued/native work after waiter cancellation.
The applied query uses this same retention, not an early release on cancellation.
The four existing canned priority responses are present at:

- `swift/PluginHost/Tests/PluginHostTests/PluginHostOwnershipTests.swift:67`;
- `swift/PluginHost/Tests/PluginHostTests/PluginBatchOwnershipTests.swift:70`;
- `telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift:50`;
- `UI/Tests/PluginUIRemediationFixture.swift:494`.

They restore admission into their original callback/ticket/effect assertions.
The eight new tests at `PluginSendHookPriorityTests.swift:84–263` cover ordering,
terminal strategies, fresh queries/ties, malformed metadata, generation and
permission retirement, late callback results and retained cancellation credit.
Their presence and assumptions were checked; they were **not run here**.

## Elyx proxy and developer seams

### ELYX-P2-01 — the actual generic constructor

The unmodified `SDK/elyx_runtime/facade.py:126–181` still calls
`base.__init__(self)`. `python/virtualjava/proxy.py:80–89` binds the first interface
FQCN and backend before user initialization; its generic base at `102–114` now
supplies the needed zero-argument initializer. This reaches the originally failing
Utilities interfaces, not just registered Runnable/OnClickListener controls.

`JavaClass.__call__:58–59` still delegates ordinary construction to the backend;
`JavaInstance.__init__:146–148` still requires its two arguments. Generic interface
base calls with unexpected constructor arguments fail, while legitimate generated
initializers and subclass `super().__init__()` succeed. Identity equality/hash
at `179–183`, class caching at `209–224`, and C handle identity are retained.
Proxy labels do not become native owner authority; the C epoch injection above
continues to govern calls. Native Runtime's read-only method contract is unchanged
by this Python constructor correction. This closes construction, not an absent
native widget-listener producer or a general JVM class-generation operation.

### ELYX-P2-02 — repaired local handoff; remaining native ingress P2

`PY/_developer.py:103` installs `_elyx_helpers.dev_command:4–19` as
`dev_server._cmd_elyx`. The original dispatcher still authenticates first at
`SDK/dev_server.py:257–284`; the shim passes `request["@"]` as command and removes
only top-level `@`, `#`, `token` framing from params. The original
`elyx_runtime/dev_commands.py:236–247` then selects its real handlers. The exact
dictionary-string unknown-command root cause is closed for local dispatch;
unknown commands and bad tokens retain failure behavior.

**Remaining P2, production witness:** an authenticated native request
`{"@":"elyx_ping", ...}` traverses
`UI/PluginDeveloperServer.swift:130–147` →
`UI/PluginDeveloperProtocol.swift:36–49` → `APP:940–997` and reaches
`Unknown native developer command: elyx_ping`. `get_elyx_plugins`,
`elyx_compare_folder` and `elyx_changes` have the same missing switch route.
No call here reaches the repaired Python dispatcher. Its interpreter-local token
is also deliberately not populated from the native listener token.

Closure of that remaining route requires authenticated native dispatch to the
appropriate captured owner worker and an explicit mapping for list/compare/change
and Host reload. The preserved local `_states`/outer loader at
`SDK/elyx_runtime/dev_commands.py:87–96,165–200` is not a host-wide registry or a
native worker reload. The archive owner's model/parser/cache work does not by
itself establish this command ingress. No archive P1 is duplicated here.

### utilities-P2-001 — native readiness, retry and stop authority

Original daemon/early-latch bodies remain at `SDK/dev_server.py:324–356` and
`SDK/extera_utils/plugin_loader.py:3635–3650`. The actual late replacement is
`PY/_developer.py:27–110`; production OWN_GIL/daemon policy still comes from
`HOST/SubinterpreterManager.swift:21–38` → `python/runtime/engine.c:265–272`.

| Reviewed branch | Actual source consequence |
|---|---|
| Valid current owner + settings grant + native-ready, enabled service | State has exactly `ready`, `enabled`, `status`; `start()` returns True and sets the latch. |
| Disabled developer mode | Python requests no start. The native start method also rejects disabled mode. |
| Starting/waiting/bind failure | `start()` stays False, latch stays false, and later calls can retry. Each start samples native state even after earlier success. |
| Missing/malformed provider reply, denied grant or missing epoch | Start reports a precise failure and returns False; it creates no Python socket/thread. Stop denial/malformed admission raises. |
| Foreign/stale native epoch or retiring owner | Provider call fails its current-owner comparison; Python's mutable fields cannot rebind C authority. |
| Retirement/grant revocation after enqueue | Queued closure rechecks the captured owner/grant; Runtime checks again on MainActor. Pending retired entries are removed; executing entries retain the live predicate. |
| Accepted stop | Returns the original void result after admission, clears the Python latch, and requests durable developer-mode off. It does not report completed socket cancellation. |

The concrete provider is `UI/PluginDeveloperBridgeExtension.swift:8–78`. It
exports only three zero-argument methods and returns readiness/status or an opaque
operation id. **No native authentication token is serialized by these methods.**
Its bounded `ExteraConfigCommandQueue` has 128 total / 32 per-owner capacity,
including executing work (`swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift:134–196`).
`releaseInstances:76–78` retires old pending entries through the real composite
release; active work checks the captured generation again at `30–40`.

Retry reaches `APP:245–254,372–376,919–924`: developer mode, engine/safe mode,
account, Host running state, maintenance/recovery and termination remain gates.
It calls `updateDeveloperServer`, never writes developerMode=true. Stop reaches
`APP:256,927–936` and `UI/PluginManagerPreferences.swift:68–95`, whose atomic-write
admission rechecks the same authority at line 92. Completion/failure remains native.

The real listener publishes a token/readiness only on NWListener `.ready`
(`UI/PluginDeveloperServer.swift:33–99`); failed startup clears its session for
retry. Stop synchronously revokes session/readiness at `43–49`, then cancels
sockets/tasks and removes its token file at `101–110`. It is a host service,
not a plugin-owned daemon that must survive interpreter destruction. These
control methods allocate no Python callback handles, and retirement adds no
reverse Python callback. No new unbalanced handle ownership was found in the
reviewed branches; that is not a freshly executed native leak test.

Local SDK manager commands now fail explicitly, and debugger commands remain
unsupported (`PY/_developer.py:12–24,104–109`; `APP:994–997`). The shim establishes
neither a debugpy session nor native Elyx live-sync.

## Verification and execution limits

**Independent checks performed here:** read-only Python 3.14.8 data/AST/hash
commands, each with a 30-second process limit. They confirmed:

- all **10** complete frozen postimages: reflection **1**, direct/send **6**,
  developer **3**, plus the **2** subsequently added fixture responses;
- actual Platform install order and both helper seams;
- the **8** new Host test definitions;
- SHA-256 pins below and **36/36** original/SDK byte comparisons.

These commands imported no SDK/plugin, opened no listener and performed no
functional/native test run. No CI, polling, network, account or external-plugin
operation was used.

| Supplied remediation receipt | Retained evidentiary scope |
|---|---|
| Core: **17 passed per CPython 3.12.10 / 3.14.8** | Configured SDK and real C recorder variants; native services/edit responses are recorders. F03's helper was explicitly joined in the author's tests. Current production installation was separately checked here. |
| Direct hooks: **6 passed per Python version** | Configured original SDK/direct facade, real C owner/transport/handles in C mode, desktop native recorders. This predates execution of the joined Host priority stage. |
| Developer/proxy: **16 passed, 1 skipped**, Windows 3.14.8 | Includes the five focused tests and actual OWN_GIL teardown; the skip is Darwin. The old C binary proves handle/proxy behavior only: it lacks the current immutable-owner/dispatcher ABI. |
| Eight new Host send-priority tests | Source present; **new compilation/execution not established** by this review. |
| Darwin developer fixture | `test_sdk_developer_native.py:35–58` now has separate **120 s compile / 10 s execution** budgets and process-group cleanup. **Unrun here**; it compiles listener/protocol/wire sources, not the PluginHost-dependent developer provider or Runtime composition. |

The new `PluginDeveloperBridgeExtension.swift` is included by TelegramUI's
shipping `Sources/**/*.swift` glob (`telegram-ios/submodules/TelegramUI/BUILD:144–149`).
Python helpers are included by the recursive SDK/runtime source inventory at
`tools/runtime/check_swift_plugin_embedding.py:380–384`. Source inclusion is not
compilation evidence.

Remaining acceptance needs the newly joined Host/provider paths, including
positive/negative Runtime metadata and controls, queued retirement/permission
revocation, old-owner callback/FIFO reclamation, and the listed core witnesses.
Historical Mac/SDK/C totals remain receipts for their own snapshots. This review
does not promote symbol flags, claim full 925 verification, or assert UIKit,
HTTP/Telegram delivery, live native Elyx commands or debugpy-session success.

## Read-time fingerprints

Raw-file hashes below use bytes without newline normalization. The **43-file**
corpus digest is SHA-256 of sorted UTF-8
`path + NUL + raw_sha256_hex + LF` records:
`22c59149938590e16b2bc224838defbc969c1c50fe556b55e9cd151d38444293`.

The 36-file SDK/original equality projection uses the same record algorithm with
paths relative to `python/sdk`:
`9eff1a8c957fd2692f821b2ae787d5b5ffbe358f69de7ac9b4023736e8571ec7`.

<details>
<summary>43 pinned reports, remediation inputs, native contracts and fixtures</summary>

```text
934059a7f38bfb6430a111664aabe2cb065f2001c75a0fff1c8ab9828936cbb1 docs/wave-2/sdk-symbols/core-api.md
df7986c5bcb4e81bc6113e5a8c165a616d8d5c421655ade6c95c54c1f89a5e84 docs/wave-2/module-routes/plugins.md
fc8d4f513fb2e62171a009bfdfe1af98502f4a726c4e78606c1c96828d316576 docs/wave-2/sdk-symbols/elyx.md
087f70351fd928711c738a0e6af67366016d33450e7ba38438310b741d74fa55 docs/wave-2/sdk-symbols/utilities.md
01e8b5052b42be458140a090c2ac2825d119e06c7009dc3f175bb34c83285a82 docs/wave-2/sdk-core-counterexample-remediation.md
b0088b4f1b7b94e27402ef799ecbada3062c23e9f362863a1f6f6ba55d5f4244 docs/wave-2/sdk-direct-hooks-remediation.md
fd8fa7071318f0245506db1eb54cc7437de73609dcd6a0d18f36bfe96c80a9f7 docs/wave-2/sdk-developer-proxy-remediation.md
7d802a960aa42d006dc9a12e55d2df7693244969f8dd40fb563d4837fb7f36e8 docs/wave-2/sdk-core-reflection-install.patch
768e9670f27a8edda9987e8792788125f590d0d8f5fcca4ffa3caa4b442352bf docs/wave-2/sdk-direct-hooks-coordinator.patch
21eb527fc37eaf52cc93fbe9ab0d7ce4dc04748dd43f17ae48a8f1a9cf3bee83 docs/wave-2/sdk-developer-proxy-native.patch
edce805b7fb3ef140ccf6bac731d39311dc04db52e2470f1e87cbe3212bb7dbe python/exteraless_runtime/_platform.py
00b016b315a43fcd7015ee4d37debf69fcc1c347b6e380ade92d06775eb03d9f python/exteraless_runtime/_tl.py
53428ff5b9a207405377d86939e582748d45e4e3a016d75f0d34552bcd92a293 python/exteraless_runtime/_scheduling.py
8f5a3e9cdd064f2d593852005b36dfff387ac6915848e430554357c7aac7ed6f python/exteraless_runtime/_reflection.py
888affeff0b233b41fda8f12f91c828fd206e61ea93146a95db7e2e981ee654f python/exteraless_runtime/_hook_registrations.py
22611badcf6c3be224e68c3f9acdefeae7edff937e1aa5a278b68b0eed27ff2d python/exteraless_runtime/_developer.py
f9a9cd73cbaf0d7ab987a1158e090935ec4fdd936f837e1801b04a2d4f0abaee python/exteraless_runtime/_elyx_helpers.py
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481 python/exteraless_runtime/_callbacks.py
8eca0d23f56a85ea87da14a22b0b8cdfb641adfc56fb5cb241e22a91ea1719cd python/exteraless_runtime/_logging.py
025acce2920244788ec5f69874228b5db459fc3a3c5b5555edeb85f10d32de92 python/virtualjava/proxy.py
f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a python/bridge/_exteraless_bridge.c
6ecab9d92438e62bd3f0d7218f9646b78f9e3f764cc5d4e9f9e5a78b85b6166d python/runtime/include/EXLPythonBridge.h
c64fda685439f416513b94c23b05bf64883cc986ba99d1dceddaa02e016ee83f swift/PluginHost/Sources/PluginHost/NativeServiceScheduler.swift
ef7e30b5c6f4fa7348760613918675d4f0976493802c7913aa4689ce7de93e5e swift/PluginHost/Sources/PluginHost/NativeServiceCallback.swift
f866c8f895a7268769b1f959f7f1bc34bebcd6e498e3720a5269155b95298c99 swift/PluginHost/Sources/PluginHost/PluginBridgeExtension.swift
e465bb340c8ac3c936677833881bba21011183c05530677e6807ce914d676a26 swift/PluginHost/Sources/PluginHost/NativeServiceWire.swift
882de607740cfd3eca62cd11d564519c987498bcd8fd862194dc21f1b6e73707 swift/PluginHost/Sources/PluginHost/PluginEventExecution.swift
35eee798ab988f79f6a2d77e512b8fedda06c1d2f3f41f4cc65e345b8e4ffefe swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift
e2ade96c9387c42cf26213caead612271615f8a5a1688a88ca02f0275bf0cced swift/PluginHost/Tests/PluginHostTests/PluginSendHookPriorityTests.swift
cecba474eb8e0bde1c7a173c8bab96c47288686e8c978366099acde315ef5b62 swift/PluginHost/Tests/PluginHostTests/PluginBatchOwnershipTests.swift
2b7d8ab6b834b314d2d263a43b1e9b9f7bffd16b8af4756e529a693597b4916c swift/PluginHost/Tests/PluginHostTests/PluginHostOwnershipTests.swift
a025555c274fa08f2b52b51f9163b33a8b50f713eea0bd103651f30e9fe32a2e python/runtime/smoke/plugins/native_hns_probe.plugin
e5f188eb63e9974deae592f41ff66a6c37a477f0d56440cca8489427fcffaf20 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperBridgeExtension.swift
4b89315efbd8f9a9705d2b4cdf457e2db1d2a4c02d84ca50c8a41b826c68be92 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperServer.swift
10264599523943c3de7d15d56688aaa5805f2a98229921cee2ae3dacb5e6f096 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperProtocol.swift
e78665ba5d8c6a3ea47dae228ed69cd03b0586e9fdff8425265eb5faed9e4f44 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginManagerPreferences.swift
e2d6d0b7942b655dd8b1fbe083a97121471a78a27e4c688762774cbedb0986fa telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift
1fd398e107730df72fba78f575f2cb656eb7d8e1d12c2aa04d799315abb907ab telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift
0e963f96e19b71b813ab9ad5e2a6bead1935e2aee906cf0319affd2d34b524d7 tools/compat/tests/test_sdk_core_counterexamples.py
4d16a7fd506f41e3f82f562e7a493fdf19f471426eee75a123082dd91c2b4dc0 tools/compat/tests/test_sdk_direct_hooks.py
f8ca2e3afdf5011d3be1ac510d073c60622e42311ffcc9c229a9cddf138b4929 tools/compat/tests/test_sdk_developer_proxy.py
eb57013f9f68a3e6bc1e43946d9e975601fae90f49e29f5d318a04bf3379ed93 tools/compat/tests/test_sdk_developer_native.py
a45f51e5e9ccef6357d9292b8c7c77296897f01d39c2970b48bb19600d99b04b tools/compat/tests/fixtures/sdk_developer/NativeDeveloperServerProbe.swift
```

</details>

Shared-file raw hashes, separately captured at 19:54:05 UTC:

```text
cf1feebdc7534faf4237a76ed32b8f81fa1f8bf19bff3ef42a72c8164223c12d python/exteraless_runtime/__init__.py
7da9cc444d453201a88f271683d9eaa706170c6059d515c4debf4db3f99be30f swift/PluginHost/Sources/PluginHost/PluginHost.swift
43938adb9f119b916addacb82bb42bc2954dc7240a340699254b836621dcc816 telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift
```

Named span hashes below use **UTF-8, LF endings, original indentation, no trailing
blank lines and one terminal LF**. Line intervals are inclusive. They permit
checking this scope independently of unrelated shared-file edits. The first
three also match the direct-hook owner's applied source projection.

| Source span | Lines | SHA-256 |
|---|---:|---|
| `PY/__init__.py#hook_priority_json` | 270–280 | `0d12441b51cb85b5f429d9dfffc687cc485fdf203386e4edb7e2e9a403526cf2` |
| `HOST/PluginHost.swift#canInvokeSend` | 1503–1508 | `12b46a69acc4d71fb05845fdd4f5c6afafaf32cd69e1dda49c6e768959db472b` |
| `HOST/PluginHost.swift#handleEvent.sendMessage` | 1540–1608 | `6c231a514e3736dbf85f2af8e166a7268e1580990b6d8d8867e1d0384de7d8d6` |
| `HOST/PluginHost.swift#invokePlugin` | 1739–1790 | `9abdb1ceba00d21126c09dbdb09daf5b21f9a28bfb7823fdc8722be44e353e90` |
| `APP#developer-composition` | 237–264 | `21e805efb46fcbd22039a2a19238419b3e967cb21aa3fa3a21615e827bc66b61` |
| `APP#developer-control-effects` | 919–938 | `9f6bea67f920a13b09e0b3a4e833b62c12ca3451c19a6bdb715ee3bdbc661b31` |
| `APP#handleDeveloperRequest` | 940–999 | `e8316abe38ead10a91bd66e1365f0e244975ddcb729e58a78cb75ef51a376b54` |
| `APP#installHooks` | 1074–1122 | `62c4231a49c5b32296090cfe99cf1f8640f0732ddb7ed477ed8b1a8666ebeeb3` |
