# Host maintenance / owner-mailbox execution gate

Source handoff. The existing `4b3f7064` / `43653040458` bridge verification does
not cover these Host changes. Swift/Apple compilation and native execution of
this maintenance implementation are **pending**; the Windows workspace has no
`swift`/`swiftc`. No CI, external plugins, accounts or network requests were run.

## Public maintenance API

```swift
public func beginSettingsMaintenance(timeout: TimeInterval = 10)
    async throws -> PluginSettingsMaintenanceLease

public actor PluginSettingsMaintenanceLease {
    public func finish(resume: Bool) async throws
}

public var isSettingsMaintenanceActive: Bool { get }
```

`beginSettingsMaintenance` reserves exclusive lifecycle admission before its first
await. Tools may snapshot/stage/replace plugin settings **only after it returns a
lease**. `isRunning == false` is not a substitute for a lease.

Preparation does the following, under one wall-clock deadline:

1. Reject new imports, installations, enable/reload/remove operations, settings,
   permissions writes, callbacks/releases and event dispatch. Metadata reads that
   create inspectors count as work too; read-only native model/log queries remain
   available. Accepted dispatcher entries retain a Host activity until execution
   or cancellation has actually drained, including entries still in its FIFO.
2. Wait for admitted operations, then await a private event-queue barrier. It
   drains the previous dispatch/timeout continuation before that actor is stopped.
   Cancelled attempts' private barriers never become plugin app events later.
3. Save the settled plugin model, enabled flags and startup policy, stop queue and
   watchdog services, and pause interpreter admission with an epoch capability.
4. Invoke SDK `unload()` on each owner, destroy the interpreter on that same
   worker, await mailbox exit, release native provider objects and revoke the
   generation token. Bridge/provider cleanup runs outside `HostState.lock`.
5. Require an empty manager (no pending creation, invocation, destroying or
   abandoned interpreter) and empty Host ownership/loading/retirement/inflight
   state. Only then publish the lease.

Native destruction is independently owned by the manager. A timeout/cancelled
wait does not erase its slot or claim that its worker exited. Failed destruction
remains abandoned and prevents a lease. A late successful destruction can be
observed by a subsequent attempt without re-running the SDK unload hook.

**Neither begin nor finish calls process initialization/finalization.** A fresh,
unstarted Host can provide a lease and finish it without starting Python. An
initialized Host keeps its one-shot CPython process alive while its plugin
interpreters are temporarily absent.

## Finish, retry and stop

- `.committed` / `.rolledBack` map to `finish(resume: true)`. Calling finish ends
  the caller's file-mutation section: the caller must make no further protected
  file writes using that lease. The manager is unpaused, queue/watchdog restarted,
  and the original enabled set gets fresh interpreters and random wire tokens.
  Safe mode preserves previously inactive plugins instead of starting them as a
  side effect of backup; previously active enabled plugins still resume.
- During this fresh startup, `isSettingsMaintenanceActive` is false (the file
  section has ended), while general Host admission stays closed until restart
  completes. Fresh loading owners can create startup callbacks/effects. The
  effect validator still rejects retiring, stopped and stale owners.
- `.needsRecovery` maps to `finish(resume: false)`: no interpreter startup and
  admission remains closed. A later `beginSettingsMaintenance` acquires a new
  attempt over the retained original snapshot/manager epoch, for journal recovery
  and eventual resume. Old leases cannot finish a newer attempt.
- Preparation failure/cancellation returns **no lease** and leaves admission
  closed. Tools must not stage/apply files. A new begin can retry after outstanding
  work/destruction settles. Abandoned native state continues to reject proof.
- Finish is single-decision/idempotent for the same Bool; conflicting decisions
  throw `superseded`. Once started, its cleanup/startup continues independently of
  cancellation of a caller awaiting the result.
- Stop wins against a preparation before lease publication. With a held lease,
  stop waits for its finish, then suppresses resume and performs terminal shutdown.
  It cannot finalize Python during the caller's leased file transaction. Concurrent
  stop calls retain the prior non-duplicating drain behavior.

Ordinary per-plugin startup failures retain the existing Host behavior: report a
load error on that model, preserve its enabled preference, and keep other plugins
available. A later maintenance still requires proof for every retained native slot.

## Exact Tools composition

The coordinator already has the compatible adapter at
`TelegramUI/Sources/ExteralessClient/Tools/ExteralessToolsHostMaintenance.swift`.
Its `begin(host:timeout:)` wraps the actual Host lease and maps all three outcomes.
Use it in the root's existing `ExteralessToolsBackupBindings`:

```swift
let bindings = ExteralessToolsBackupBindings(
    settings: ToolsBackupSettingsAccess.clientSettings(ClientSettings.shared),
    pluginLocation: {
        ToolsBackupPluginLocation(
            directory: try services.serviceStorage.settingsDirectory(),
            exportableFields: cachedNonSecretKeys // [String: Set<String>], native metadata
        )
    },
    beginMaintenance: {
        try await ExteralessToolsHostMaintenance.begin(host: host, timeout: 10)
    }
)
```

The adapter is equivalent to:

```swift
let lease = try await host.beginSettingsMaintenance(timeout: 10)
return ExteralessToolsMaintenanceLease { outcome in
    switch outcome {
    case .committed, .rolledBack: try await lease.finish(resume: true)
    case .needsRecovery: try await lease.finish(resume: false)
    }
}
```

Before normal startup, the coordinator's existing
`ExteralessToolsHostMaintenance.recoverBeforeStart(host:settingsDirectory:settings:)`
holds the same real lease around `ToolsBackupRestorer.recover`. Do not replace this
with stop/start. A no-Host lease is appropriate only when the root knows no Host /
plugin workers were created; an inactive/starting/failed Host is not that proof.
Inspection/export remain data-only and do not acquire a lease by starting Python.

## UI mailbox gate and bounded terminal delivery

The added defaulted parameter is propagated end to end:

```swift
dispatcher.callback(owner, handle, method, json,
    shouldExecute: { gate.permits(owner: owner, argumentsJSON: json) },
    guaranteed: PluginUICallbackGate.isTerminal(argumentsJSON: json))

try await dispatcher.result(owner, handle, method, json,
    shouldExecute: { gate.permits(owner: owner, argumentsJSON: json) })

try await host.invokeCallback(id: id, handle: handle, method: method,
    argumentsJSON: json, expectedOwner: owner, shouldExecute: predicate)
// invokeCallbackResult has the same predicate and returns the actual JSON string.
```

`SubinterpreterManager.invoke(..., shouldExecute:)` evaluates the predicate in the
mailbox immediately before `engine.runScript`, after earlier owner jobs. The Host
also revalidates its generation there. False returns `PluginHostError.superseded`,
without Python entry; awaited results complete with that error. Result cancellation
is checked again at this same boundary. Predicates must use Foundation-safe state,
not UIKit/main-actor access. Defaults remain `{ true }`.

Callbacks, terminal bookkeeping and `release_handles_json` share one FIFO per
captured owner; different owners can progress in parallel. Budgets include executing
work and are released only when it drains, even if a result's caller cancels early.

| Budget | Data lane | Reserved control lane |
|---|---:|---:|
| Global work count | 1024 | 1024 |
| Per-owner count | 256 | 128 |
| JSON payload per callback | 16 MiB | 16 KiB |
| Outstanding payload bytes | 32 MiB | 4 MiB |

`guaranteed: true` selects the control lane; it is not an unlimited bypass. Releases
use that lane too, retain the existing maximum of 4096 positive handles per call,
and charge their bounded Int64 storage. Method names are capped at 256 UTF-8 bytes.
Limits can be reduced through `PluginCallbackDispatcher.Limits`; its initializer
never raises the production caps. Native UI's 16 presentations + 64 menus per owner
need at most 96 terminal/release entries at once, within the default owner reserve;
providers must also budget combined outstanding work rather than assume unlimited
control capacity. Control can be refused for invalid/retired owners or exhaustion.

`callback` and now `release` return admission Bool (`release` is discardable for
existing callers); `result` throws on refusal. Root/provider code must handle false.
An admitted closed callback follows its action, even if the action throws; release
follows closed. During maintenance/new-owner retirement, refusals are intentional:
SDK unload and generation-scoped native cleanup retire those leases instead.

## Verification supplied

- `PluginHostMaintenanceTests`: 12 bounded fake-engine scenarios for draining queued
  callbacks/inspectors, enabled flags, fresh tokens, headless maintenance, recovery,
  cancellation, failed/timed-out destruction, stop races and admission/effect gates.
- `PluginCallbackGateTests`: 6 scenarios for actual-worker predicate evaluation,
  queued expiry, result JSON/cancellation, bounded terminal FIFO, parallel owners
  and pending-creation proof.
- Every synthetic blocking gate has a 5-second escape; waits use bounded deadlines
  or continuations. No external plugin, network, account or real message is used.
- `PluginHostOwnershipTests` uses `onOwnedCallback` and validates the wire token.

Pending on the native runner: compile and run these suites plus existing Host,
SubinterpreterLifecycle and bridge tests; then execute the real C-owned probe with
immutable owner binding, maintenance/resume and the coordinator's UI predicates.
UIKit/account-switch evidence remains separate from these Foundation tests.
