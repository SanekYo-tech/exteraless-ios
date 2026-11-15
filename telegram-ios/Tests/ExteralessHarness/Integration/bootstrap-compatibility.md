# Frozen harness bootstrap contract — App / Retention owners

## Joined public API adapter (final visual source cohort)

The versioned environment and `ExteralessAccountRecoveryCenter.pending` /
`ExteralessAccountRetentionRecovery.currentStatus` APIs are now present. The
harness implements `ClientHarnessReadiness.swift` using those public native
signals around the existing constructor: a typed failed owner is disposed and
reported, and only native authorized completion succeeds. This addresses the
NoError-wrapper point described below without a Composer/Account/Retention edit.
There is one fixture factory per fresh process, no automatic retry/reset, and
all preparation/retention/transport order below still applies. `prepare` gained
an optional `scenario:` argument only for the two newly authorized visual inputs.

Handoff for the PFR01/PFR04 versioned-unavailable and typed-readiness/retry join.
The original 3+3 cohorts are frozen; the explicit final-visual cohort reuses this
bootstrap. The original compatibility note below requests compatibility or an exact
coordinator-applied join patch; it does not modify Account/Retention or add a test.

## Exact current caller and ordering

`Sources/ClientHarnessApplication.swift`, `ClientHarnessSession.bootstrap`, awaits
`ClientHarnessBootstrap.prepare(directory:domain:)` on its settings worker **before**
calling `HarnessAccount.make()`. That is before its first AccountManager/Postbox
writer and both account/network construction passes.

`Sources/ClientHarnessBootstrap.swift` currently calls these public APIs:

```swift
let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
try ClientSettings.shared.configure(
    storageURL: directory.appendingPathComponent("native-client-settings.json"),
    secretStore: privateStore,
    durabilityRootURL: container
)
try ClientSettings.shared.register(RetentionFeatures.definitions)
// Domain cases additionally register Chat/Feed/Player/Pill definitions and
// atomically arrange their explicit offline settings before taking this snapshot.
let retention = try ExteralessRetentionProcessConfiguration(
    role: .mainApplication,
    snapshot: ClientSettings.shared.readSnapshot(),
    durabilityRootURL: container
)
try ExteralessAccountRetentionEnvironment.shared.configure(retention)
let configuration = ClientAPIConfigurationStore(
    settings: .shared,
    settingsSecrets: privateStore,
    vault: ClientAPIVault(storage: privateStore)
)
try ExteralessClientAPIEnvironment.shared.configure(
    builtinApiId: 1,
    builtinApiHash: "11111111111111111111111111111111",
    configuration: configuration
)
```

`privateStore` is the harness's synchronized in-memory `ClientSecretStore` +
`ClientAPISecureStorage`, including atomic `insertIfAbsent`. The tuple is synthetic.
The native API resolver/pin/marker path still executes; no system Keychain or real
account/API credentials are available to the fixture.

The Account constructor/retainer sources come from
`//Tests/ComposerHarness:DisposableAccountSources`, compiled as
`ClientHarnessAccount`. `HarnessAccount.make()` returns
`Signal<HarnessAccount, NoError>` and internally uses the genuine
`accountWithId(...) -> Signal<AccountResult, NoError>` twice. It supplies
`supplementary: true`, `backupData: nil`, `shouldKeepAutoConnection: false` and a
new `composer-harness-<UUID>` directory. SOCKS5 `127.0.0.1:1` is committed before
the first account open. **The process role is still `.mainApplication`**:
supplementary disables account synchronization, not retention admission/readiness.

## Compatibility required from the native join

1. Preserve the public constructor/configure call shapes above, or supply an exact
   patch for the named harness callsites together with the native API change.
   Keep the injected private-store and OS-container arguments; no entitlement,
   additional secret, fake Account, default-policy fallback or readiness bypass.
2. A fresh, fully registered valid store and empty retention archive must still
   lead to one finite successful authorized Account result **after genuine retention
   readiness**, with the real cache/writer barriers in effect. Success cannot be
   announced while policy is unavailable or before its generation is admitted.
3. A versioned unavailable state must revoke the same generation's pending work
   and readiness. Recovery must reject older publications/completions and admit
   only the current newer valid generation. The fixture's valid startup is not an
   exemption from PFR01's revocation rules.
4. Retention failure remains a typed, terminally observable failure at the account
   factory boundary until explicit recovery/retry. Do not convert it to successful
   readiness, erase an archive, or keep the old policy solely to make the UI gate run.
   The frozen UI batch exercises the fresh-archive happy path; it does not claim to
   test corruption/recovery or replace the owners' PFR fixtures.

## If the typed result affects the wrapper

**Important adapter point:** the current Composer constructor's final
`mapToSignal` accepts `.authorized` and returns `.never()` for another result.
Adding an `AccountResult` failure case alone would therefore hide that failure in
this wrapper until the external deadline. Its first-pass `.unauthorized` branch
also needs to preserve any new failure outcome instead of retrying it as login.

If the new result/error channel changes this behavior or breaks conformance,
App/Retention owner should hand the coordinator an exact adaptation for
`Tests/ComposerHarness/AppContext/HarnessAccount.swift` (or a public constructor
error-forwarding seam), plus any required change to
`ClientHarnessSession.bootstrap`. Preparation errors already reach
`ClientHarnessReport.fail`; account-readiness errors need the same named failure
route, with owning subscriptions disposed. Keep process-scoped storage retention
and the loopback-before-construction ordering. No automatic unbounded retry or
`.catch` that returns a fabricated Account/readiness value.

The same `.ipa` serves two explicit serial recording invocations. Each invocation
still creates its own simulator and runs at most three fresh app processes, each
bounded at 30 seconds. This handoff requests no additional scenario, retry loop,
process, recording, or deadline extension. The coordinator records only after the
joined native cohort compiles; native/visual acceptance remains pending.
