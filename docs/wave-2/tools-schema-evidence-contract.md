# HNS-01 — exact Tools Core schema-evidence contract

For the Runtime/UI owner and coordinator's joined patch. The independent
`reviews/host-native-services.md` is read-only. The Core types, cache revocation and
read/commit checks are applied, with bounded regression fixtures supplied. The
Runtime/UI joined patch and native execution remain with their owners; today's
Python SDK does not guarantee immutable schemas.

## Public Core types / signatures

```swift
public struct ToolsPluginSchemaEvidence: Equatable, Sendable {
    public enum Guarantee: Sendable { case unprovenDynamic, nativeImmutable }
    public let accountId: Int64
    public let owner: String
    public let sourceURL: URL
    public let sourceSHA256: String
    public let settingsRevision: UInt64
    public let settingsSHA256: String? // nil = absent file; not the hash of "{}"
    public let schemaSHA256: String   // exact already-returned native settings JSON
    public let guarantee: Guarantee
    public init(accountId: Int64, owner: String, sourceURL: URL, sourceSHA256: String,
                settingsRevision: UInt64, settingsSHA256: String?, schemaSHA256: String,
                guarantee: Guarantee = .unprovenDynamic)
}

public enum ToolsPluginSchemaUse: Sendable { case export, restore }

public protocol ToolsPluginSchemaValidity: Sendable {
    func withCurrent<T>(evidence: [String: ToolsPluginSchemaEvidence],
                        use: ToolsPluginSchemaUse, _ body: () throws -> T) throws -> T
}

ToolsPluginSchemaCache.record(fileName: String, owner: String,
    cachedNativeSettingsJSON: Data, evidence: ToolsPluginSchemaEvidence? = nil) throws
ToolsPluginSchemaCache.location(directory: URL, activeOwners: [String: String],
    validity: (any ToolsPluginSchemaValidity)? = nil) throws -> ToolsBackupPluginLocation

ToolsBackupPluginLocation.init(directory: URL, exportableFields: [String: Set<String>],
    schemas: [String: ToolsPluginSettingsSchema] = [:],
    evidence: [String: ToolsPluginSchemaEvidence] = [:],
    validity: (any ToolsPluginSchemaValidity)? = nil)
```

The protocol has a **synchronous, nonescaping generic body**, not an asynchronous
callback or a Boolean checked once when creating a location. A conformer must pin
the native authority across that body's actual I/O. It may use a lock-only native
snapshot/admission lease; it must not wait for MainActor, call Python, acquire a new
current owner by pluginId, or execute a user callback. Do not hold Host interpreter
locks or call ClientSettings setters from the guard itself.

Evidence keys are the native settings filenames. `record` checks owner and exact
schema digest; replacement/invalidation of a cache entry revokes captured locations.
`ToolsPluginSettingsSchema.renderedJSONSHA256` binds the derived field map to the
exact cached JSON that produced it; an independent hand-built allowlist is not enough.
Core also verifies **fd-bound source bytes and exact settings-file bytes**, before
the read/application boundary, rather than trusting producer hashes alone. Native
validity must check account, owner/source generation, settings revision and the
authority for the pinned maintenance operation. Revision changes on every settings
write, including same-value writes, deletes and unload callbacks. It is not an mtime.

## When evidence can be issued

| Source | Permitted authority |
|---|---|
| Arbitrary Python `create_settings()` | `.unprovenDynamic`; never grants plugin backup permission |
| Cached UI result with only account/epoch/hash | `.unprovenDynamic`; snapshots alone cannot prove a stateful/time-dependent function's current schema |
| Native-enforced immutable declarative schema, with verified installed source and stable snapshot/revision | `.nativeImmutable`, only while the native validity pin remains valid |

**Current SDK fact:** it calls `instance.create_settings()` again and does not enforce
immutability. A plugin-provided `immutable: true`, a comment, repeated equal JSON, or
absence of observed `set_setting` calls does not supply that guarantee. Until the SDK
owner supplies an enforced declaration contract, the UI owner must pass nil evidence
or `.unprovenDynamic` for arbitrary plugins. Those schemas are skipped for export
and rejected for restore. No settings/Python request is added to refresh them.

`nativeImmutable` means permissions/types/ranges remain valid across the requested
restore's value changes, not just that S1 described the old values. A schema that
narrows to S2 after changing `mode` cannot receive this guarantee. Supporting such
schemas later requires a native target-schema evaluator/proof; cached S1 is not one.

## Actual boundaries and maintenance order

1. Native UI obtains schema JSON through its ordinary request. Capture source,
   exact settings bytes/revision, account and expected owner coherently around that
   request. If values/source/owner change during capture, discard the evidence.
2. Record the schema with that evidence; location creation alone is not authorization.
3. **Export:** a captured location uses `withCurrent(..., use: .export)` at file I/O,
   verifies source/settings hashes through pinned descriptors and checks cache
   invalidation. No Python, mkdir or Host startup is allowed in this path.
4. **Restore:** acquire actual Host maintenance, wait for its full drain/unload, then
   use `withCurrent(..., use: .restore)` for validation/read and again at the actual
   plugin-directory commit. An unload write invalidates the old settings revision/
   hash and must reject S1. A frozen pre-drain map by itself is insufficient.
5. Retired callback owners may only be represented by the **same proven maintenance
   operation's** pinned authority; substituting a newly resolved owner is forbidden.
   Native install/reload/account replacement is excluded by that pin across I/O.
6. Release/invalidate evidence when the maintenance operation ends or settings,
   source, owner/account or schema changes. Direct Tools directory writes must also
   invalidate subsequent export permissions. Do not fetch Python settings to do so.

Core's ordinary config archive and TB-01–06 conservative rollback/reconciliation
contracts remain in force. Client-only imports/recovery do not require plugin schema
permission; keep-current reconciliation performs no plugin-value write. Confirmed
in-call rollback uses its own TB-02 receipt under the still-held Host lease, not an
old export schema as an ownership witness.

## Migration / default denial

Old `record`/`location` calls remain source-compatible through optional parameters,
but **grant no plugin export permission** without native immutable evidence and a
validity guard. A manually constructed nonempty allowlist is also insufficient at
Core read/apply; it must have matching schemas/evidence and a validity guard.
Empty plugin locations used for client-only recovery continue to work.

Supplied `ToolsSchemaEvidenceTests` regressions: S1/value-write/S2 within one owner; unload write after
freeze; owner/source replacement between location and I/O; revoked captured entry;
unproven dynamic schema denied; real export performs no Python request. Native
producer/guard integration is supplied by the UI owner and joined by coordinator.
The native pin checks metadata before/through the synchronous body; own restore
file writes can invalidate future export permission without being mistaken for a
foreign write. Export additionally rechecks cache generation after reading. Actual
settings hashes are taken from the same bounded fd reads/manifests already used by
Tools, preserving TB-06's pre-materialization aggregate budget.
