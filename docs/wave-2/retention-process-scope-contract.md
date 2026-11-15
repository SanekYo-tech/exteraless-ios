# Retention process scope — PR05 / PR14 contract

## PFR01 / PFR04 — updated consumer API (2026-11-15)

This versioned API supersedes the unversioned update and Bool-only factory wait below.
The App owner publishes **every** environment transition, including unavailable after a
settings commit failure, through one increasing version stream:

```swift
let state = ExteralessRetentionConfigurationState(
    version: environmentVersion,
    availability: .available(loadedConfiguration) // or .unavailable
)
let owner = ExteralessRetentionAccount(
    postbox: postbox, accountPeerId: authorizedPeerId, configurationState: state
)
owner.updateConfiguration(nextState)
```

- `updateConfiguration(_ state: ExteralessRetentionConfigurationState)` ignores versions
  <= the last accepted version. Unavailable synchronously clears policy/maintenance admission,
  revokes the work epoch and readiness token, and terminates pending readiness with
  `.configurationUnavailable`. The first valid process role/root remain pinned through failure.
- Forward unavailable to **both** Account and standalone owners; do not filter nil/error
  states. Marshal versions at the environment boundary, not independently in each subscriber.
- `awaitReadiness(timeout: Double = 5)` returns one
  `Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>` then completes.
  Failures: `.configurationUnavailable`, `.archive(ExteralessRetentionError)`, `.cancelled`,
  `.timedOut`. An invalid/unsupported index is an archive failure; it is not erased automatically.
- At each final factory/transfer boundary call `owner.isReadinessCurrent(token)` before using
  success. Policy invalidation/retry/reset/disposal revokes previously returned tokens.
- `retryReadiness(timeout: Double = 5)` begins a fresh attempt and returns its one terminal
  result. Replace/dispose the previous retry subscription; a superseded retry cannot continue.
- `resetArchiveForRecovery()` exposes the existing **explicit**, main-role-only, journaled
  reset as `Signal<Result<Void, ExteralessRetentionError>, NoError>`. Present this choice before
  requiring an Account. After a successful reset or external repair call `retryReadiness()`.
- Default maximum wait is 5 s; a supplied timeout is clamped to 0.01...25 s. A compatibility
  `ready` accessor can only emit true on a real success; factories must handle typed failures.
  The older configuration constructor represents version 0; all updates are versioned.

The environment's ordered publications, Account/standalone bindings, typed pre-Account
retry/reset UI and NotificationService startup disposable are App-owned. Retention supplies
the owner API and native fixtures; it does not edit those consumers.

PFR05 also supplies `retention-followup-coding-hunk.patch`: one call in the existing
`AccountManager.swift` once-only coding declarations. The retained local-file subclass keeps
its routing provenance through native encoding. Register it alongside `LocalFileMediaResource`
before concurrent Postbox use; the global coding dictionary is not a runtime-mutated registry.

2026-11-15. **FROZEN source API contract** for the App owner. Implementation/remediation facts are in
`retention-review-remediation.md`; this is not a native-execution receipt.

## Required App-owned construction order

1. Configure/reload the actual shared settings file with its OS durability root.
2. Register `RetentionFeatures.definitions` before obtaining `readSnapshot()`.
   Registration must have succeeded; propagate preparation failure before replay.
3. Construct the immutable configuration using the new TelegramCore API:

   ```swift
   let retentionConfiguration = try ExteralessRetentionProcessConfiguration(
       role: .notificationService, // .mainApplication / .shareExtension at those roots
       snapshot: ClientSettings.shared.readSnapshot(),
       durabilityRootURL: actualContainerURL
   )
   ```

4. Construct the writer-owned service **before** the writer starts replay:

   ```swift
   let retention = ExteralessRetentionAccount(
       postbox: postbox,
       accountPeerId: authorizedPeerId,
       configuration: retentionConfiguration
   )
   ```

5. Keep this service strongly for the entire writing Postbox lifetime. The standalone
   NotificationService state manager needs its own service because it creates no `Account`.
   The authorized `Account` owns the service for ordinary and Share accounts. Never attach
   two services to the **same** Postbox/MediaBox; use a separate writer's actual Postbox.
6. `ready` emits true after the observer and native leases reach their owning queues.
   Await it before replay/cache eviction. A missing configuration does not select default
   retention limits: that compatibility initializer is inert, reports `.unavailable`, and
   emits no true readiness until `updateConfiguration(_:)` receives a loaded configuration.
7. After a successful settings reload, pass a fresh configuration with the same process role
   and durability root via `updateConfiguration(_:)`. No reload/default substitution is done
   by a native getter. Dispose the service at writer teardown, including standalone cancellation.

The constructor/configuration update/readiness wiring is App-owned in `Account.swift`,
NotificationService, Share and the composition root. Retention does not edit those files.

## Role and media ownership contract

- All configured roles may capture known received before-images and authenticate/materialize
  their owned files. Capture uses the explicit snapshot, including a user's 90-day setting.
- Only `.mainApplication` performs automatic destructive maintenance and GC. Extension
  capture may retire entries to meet the **loaded** limits; retirement is journaled in the
  same encrypted Postbox transaction, and the main writer drains that durable deletion work.
- An account-local, non-deleted OS lock file serializes retention file publication, restoration
  and deletion across processes. Postbox transactions never wait for that file lock. The file
  worker acquires the lock before fresh Postbox ownership admission, not after using a stale
  in-memory keep set. New reservations cannot reuse journaled native IDs/tokens.
- A deletion credit is an exact token/native-ID retirement in the encrypted journal. Only
  a still-unowned credit can be drained; successful removal and directory sync precede its
  acknowledgement. Missing ciphertext is not evidence that native plaintext was removed.
- The supplied durability root must be an existing trusted account/container ancestor of the
  vault. File and directory-chain barriers are required on initial publication and recovery.

Core `RetentionPolicy*` remains frozen. `RetentionProcessScope.swift` owns this native contract.
