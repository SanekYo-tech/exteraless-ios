# Ready Tools contract — coordinator / native UI integrator

This supersedes the phase-1 dictionary-only backup setter in `tools.md`.
For the current **journal v3 / conservative restart / explicit reconciliation**
contract, see `tools-remediation.md` (TB-01/02). The actual public batch API is unchanged.
HNS-01 now requires `tools-schema-evidence-contract.md`; epoch-only cached schemas
grant no plugin permission. CA-01/02 require admitted projection and exclude native
API identity/key-export consent from general backup writes.
No common runtime/AppDelegate file was edited by the Tools owner.

## Atomic public settings binding (ready)

```swift
let access = ToolsBackupSettingsAccess.clientSettings(ClientSettings.shared)
```

The factory calls the actual `applyPublic(values, resetting:..., expected:...)`
batch from `settings-batch.md`. Snapshot capture retains public effective values,
**storedKeys**, definitions and learned secret classification. Expected snapshots
come from the pre-recorded before/target image, never a post-failure native read.
Storage errors are classified uncertain/durability; pre-write rejections (including
CAS) are distinguished. No Keychain getter or one-key set/reset loop is used.

Archive v2 records `clientStoredKeys`; an absent key is restored using resetting.
Archive v1 remains readable with its original explicit-value semantics. Journal v3
records both affected-key images + presence and original/target plugin file hashes,
with diagnostic client/directory dispositions. They are not restart write witnesses.
Nonterminal v2/v3 target equality never authorizes automatic rollback after restart;
the recovery UI can explicitly keep current state and archive the retained evidence.
Uncommitted v1 journals lack the necessary information and are retained for review,
not guessed into persistent defaults. Committed v1 journals only need cleanup.

## Native cached schema contract (ready, no extra Python request)

Retain `ToolsPluginSchemaCache()` in the application composition/runtime adapter.
At the **existing** successful native UI `settingsJSON` completion:

```swift
let fileName = try ToolsPluginSchemaCache.settingsFileName(pluginId: pluginId)
try schemaCache.record(fileName: fileName, owner: capturedOwnerToken,
                       cachedNativeSettingsJSON: Data(alreadyReturnedJSON.utf8))
```

Use the captured native random owner epoch from `native-owner-token.md`, scoped
with the native AccountContext record ID when the settings schema is account-specific
(for example `"account:\(context.account.id.int64):epoch:\(owner.wireToken)"`). Do not
derive it from a plugin's supplied JSON, pointer description or a newest-owner
lookup after suspension. Invalidate on unload/reload/source change and clear on
runtime replacement. Failed schema parsing invalidates the old permission.

`location(directory:activeOwners:)` returns a typed `ToolsBackupPluginLocation`
with key/type/range restrictions. `activeOwners` maps exact settings filenames to
the authoritative epochs. While a maintenance lease retires instances, use the
lease's frozen pre-pause epoch/schema mapping; do not run get_settings to rebuild it.

Only known switch/selector/slider fields are admitted automatically. Text inputs
require the cached native annotation `backup_exportable: true`; `is_secret`,
`sensitive`, `backup_exportable: false`, credential-key detection and unknown widget
types deny export. Only derived schema metadata is retained, never the JSON's values.
Empty/missing/current-owner-mismatched schemas grant **no** exportable fields.

## Maintenance binding

Tools' current facade takes:

```swift
ExteralessToolsBackupBindings(
    settings: access,
    pluginLocation: { try schemaCache.location(directory: settingsDirectory,
                                               activeOwners: frozenOwners) },
    beginMaintenance: beginMaintenance
)
// beginMaintenance: @MainActor () async throws -> ExteralessToolsMaintenanceLease
// lease.finish: @MainActor (Outcome) async throws -> Void
// Outcome = committed | rolledBack | needsRecovery
```

The actual Host API is now present in `PluginHost.swift` / `PluginHostLifecycle.swift`:
`host.beginSettingsMaintenance(timeout: 10)` returns `PluginSettingsMaintenanceLease`,
whose `finish(resume: Bool)` is a single-decision async operation. The ready Tools
adapter is `ExteralessToolsHostMaintenance.begin(host:timeout:)`; it maps committed/
rolledBack to resume=true and needsRecovery to false. It invokes no start, terminal
stop or finalization. Data-only inspect/export invokes neither this adapter nor
get_settings/Python startup.

Exact coordinator startup hunk, at the existing `try await host.start()` in
`ExteralessPluginRuntime.start()` (the UI integrator owns this file):

```swift
let settingsDirectory = try self.services.serviceStorage.settingsDirectoryURL()
try await ExteralessToolsHostMaintenance.recoverBeforeStart(
    host: host, settingsDirectory: settingsDirectory)
try await host.start()
```

The wrapper acquires the real lease on a fresh host, runs recovery on a worker,
then resumes the not-yet-running host without initializing Python. On failure it
finishes resume=false and throws, so startup remains blocked. Recovery needs no
plugin schema execution. Without an atomic write witness it holds ambiguous journals
for explicit reconciliation; optional fresh readonly already-before confirmation
does not call setters. The readonly path getter/startup call is coordinator-applied.

For an already running host, supply
`beginMaintenance: { try await ExteralessToolsHostMaintenance.begin(host: host) }`.
Keep the schema provider's frozen pre-pause owner/schema map available through
finish; callbacks/current owners are retired by the Host lease. Capturing that map
must be serialized with native install/reload admission. If the composition cannot
prove that ownership, it must refuse plugin-data restoration (client-only recovery
still works), never fetch fresh settings by executing Python during backup.

The coordinator has already added the context-aware MainRoot launcher forwarder:
`handleToolsShortcut(type:context:completion:)`. Do not replace it with the old
two-argument phase-1 example. Only `tools.configure(backupBindings:shortcutBindings:)`
remains to be supplied by the owning composition after the same AccountContext
identity check.

## Trace producer hunk for ExteralessPluginRuntime owner

**Applied by the UI integrator** in current source (setEnabled contains the real
record call). Retain this code; do not add a second timing record.

`ToolsToggleTraceBuffer.shared.record(pluginId:enabled:elapsed:succeeded:)` is ready.
Inside the existing `setEnabled(id:enabled:)`, after imports include ExteralessCore:

```swift
let started = ProcessInfo.processInfo.systemUptime
var succeeded = false
defer {
    ToolsToggleTraceBuffer.shared.record(pluginId: id, enabled: enabled,
        elapsed: ProcessInfo.processInfo.systemUptime - started, succeeded: succeeded)
}
// Keep existing await-ready, native setPluginEnabled, subscription refresh,
// didChange and loadError checks. Then, at the successful end only:
succeeded = true
```

No extra host call is introduced. Last 40 durations feed the existing Diagnostics
export; this is actual operation wall time, not a fabricated Python/GIL sample.
Shortcut AppDelegate cases and the ClientRuntime forwarder remain in `tools.md`.
