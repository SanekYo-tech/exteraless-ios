# Core settings — handoff

## Independent-review remediation

SC01–SC08, native cold-start credential repair, and the AI04 closed-shape boundary
are addressed in [settings-remediation.md](settings-remediation.md). That handoff
supersedes earlier notes about numeric acceptance, failed schema loading, secret
default clearing and directory publication. It includes the required app-group
`durabilityRootURL` binding and the strict raw-JSON bridge API. Shape names and
initializer placement are in [settings-shape.md](settings-shape.md).

## Public batch/CAS subwave

The baseline Core at `496d426` passed coordinator CI `43645893132` (15 Core tests,
plus existing Host/Hooks). The next Core-only patch adds
`applyPublic(_:resetting:expected:)`, targeted disk-state CAS and absent-override
rollback support. Exact API, Tools journal/binding requirements and verification
status: [settings-batch.md](settings-batch.md). The new patch needs a fresh test
pass; the earlier CI result is not evidence for these additions.

## Scope / status

Implemented source: Foundation-only settings infrastructure and a native
Display-hosted settings root, selectors and editors. Domain registration and the
application/PeerInfo insertion remain coordinator-owned. This infrastructure does
not assert that any appearance/chat/privacy/AI/tools feature has been applied.

Original reference: `ExteraConfig.java:60,80–96` (`PREFS_NAME = "exteraconfig"`,
`getPreferences`, `getEditor`/`MappedEditor`) supplies the persistent-settings seam;
the original itself identifies compatibility-storage-only fields at lines 50–51.
The JSON/Keychain backend and native grouped-list root are **iOS adaptations**.
Feature symbols/defaults remain the respective domain definitions' responsibility.
No Android preference dump is imported automatically.

Read: `docs/wave-2-contract.md` in full, `telegram-ios/AGENTS.md`,
`telegram-ios/CLAUDE.md`, PluginManager/PluginSettings/PluginUIHelpers and
AccountContext's existing `ExteralessPluginEntry`.

## Owned files

- `swift/ExteralessCore/Package.swift`: Swift 6, iOS 15/macOS 12, no package dependencies.
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift`
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift`
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSecrets.swift`
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsObservation.swift`
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift`
- `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift`
- `telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsEntry.swift`

## Stable API and additional seams

All signatures from the wave contract are present, including the exact
`ClientSettingDefinition` initializer and `ClientSettings.shared` methods:
`configure(storageURL:)`, `register`, `bool(_:default:)`, `integer(_:default:)`,
`double(_:default:)`, `string(_:default:)`, `value`, `set(_:for:)`, `snapshot`,
`definitions`, `reload`, `observe`. Observation tokens support `cancel` and deinit.

Additional public APIs:

```swift
try ClientSettings(storageURL: url, secretStore: backend) // initial read is synchronous
try ClientSettings.shared.configure(storageURL: url, secretStore: backend)
try ClientSettings.defaultStorageURL()

try definition.validate(value)
let normalized = try definition.validatedValue(value)
let view = settings.readSnapshot() // definitions, values, storedKeys, secretKeys, lastError
let error = settings.lastError
try settings.reset(key)             // removes override / Keychain item
try settings.migrateKey(from: oldKey, to: registeredKey)
let data = try settings.exportJSON()

public protocol ClientSecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data?, for key: String) throws // nil means delete
}
// Apple only; supply an accessGroup ONLY if already entitled:
ClientKeychainSecretStore(service: "exteraless.client-settings", accessGroup: nil)
```

`ClientSettingValue` is transparent Codable JSON (not Swift's synthesized
associated-enum envelope). Int64 is preserved, bool is distinct from numeric 0/1,
non-finite numbers and excessive nesting are rejected recursively. JSON has no
independent integer/double type marker: integral Double JSON tokens may decode as
`.integer`; a registered numeric definition restores its declared numeric kind.

Registration is idempotent. Same-type definition updates can change localized
fallback labels, options and defaults if stored values still validate. Type
changes and secret-to-plaintext downgrades fail. All values/defaults/options are
validated before schema publication. Invalid stored enums/ranges cause a visible
error, not a rewrite with defaults. `.null` defaults accept any valid JSON kind;
other definitions enforce their kind, with exact (non-lossy) numeric conversion.
Step is anchored at minimum, or zero; integer steps use integer remainder.

## Persistence, migrations, concurrency

- Default file: `<Application Support>/exteraless/client-settings.json`.
- Getters only read the synchronized memory cache; no file/Keychain reads on a hot
  native getter. `readSnapshot` is one cache generation, including definitions.
- Writes serialize per instance and use a sibling `.lock` with `flock` across
  instances/processes on Darwin/Linux. Each writer reads the current disk document
  under that lock, so stale process caches cannot discard other writers' keys.
- Temporary file in the same directory, mode 0600, complete write, `fsync`, atomic
  `rename` over the destination, directory `fsync`; newly created directory links
  are synchronized as well. No remove-then-move gap.
  Filesystem/backend errors contain only operation/status codes, never payloads.
- A corrupt/unsupported document is preserved. Reload failures retain the last
  complete cache; every write revalidates disk. A post-rename durability error
  publishes the committed cache and throws; failures also attempt read-only
  recovery because Keychain/file operations cannot form one shared transaction.
- Current envelope: `{"$format":"exteraless.client-settings","version":1,
  "values":{...},"secretKeys":[...]}`. Unknown setting keys and unknown envelope
  metadata survive writes. Unknown values are not exposed in snapshots/UI.
- Plain legacy dictionaries and version-0 envelopes migrate on registration or a
  mutation. Loading before definitions exist does not rewrite a legacy document.
  `migrateKey` is idempotent, destination-wins, and validates its destination;
  there are no domain-specific names in Core.
- Defaults stay in memory; reset removes an override rather than persisting the
  current default. No SQL/account/message database is opened.
- Subscribe **before** reading the initial snapshot. No initial callback is fired.
  Callbacks receive invalidation keys, run outside all locks on the writer's
  thread, and can re-enter the store. Empty keys invalidate error/storage status.
  Concurrent delivery may overlap; re-query current values, do not infer a value
  from event order. Cancellation prevents future delivery; an in-flight callback
  may finish. Each process explicitly reloads on the appropriate lifecycle; no
  cross-process notification mechanism is invented.

## Secrets — important consumer boundary

Apple uses generic-password Keychain items with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no synchronization, and no
invented access-group entitlement. The service name is stable across container
moves; storage URL alone does not namespace Keychain items. Tests inject a backend.
Secret defaults must be empty strings/collections (or scalar/null defaults), and
secret enum literals are rejected. Structured secret arrays/objects are supported
for native domain consumers.

**`value` and typed getters are native accessors and can return real secrets.**
This is required by the AI structured-settings consumer. `snapshot` and
`readSnapshot.values` always replace secret values with `.null`; `exportJSON`
omits secret keys entirely. The root never fills an editor with a stored secret.
The generic plugin `getClientSetting` bridge should use `snapshot()[key]` and its
own fallback/permission policy, not `value`/`string`; generic plugin writes to
secret definitions also need the coordinator's explicit access policy.

Coordinator integration now uses a coherent `readSnapshot` for plugin reads and
`setPublic(_:for:)` for writes. The latter checks secret classification inside the
writer transaction, including a previously failed plaintext-to-secret migration,
and raises `secretAccessDenied`. Native AI/domain callers retain `set`/typed getters.

Known plaintext secrets in legacy JSON move to Keychain **before** JSON is
scrubbed. If secure storage fails, the source file remains recoverable and the
operation throws. Persisted `secretKeys` classification prevents a later build
from treating an older secret as a normal setting. A versioned file with plaintext
under a marked secret key is rejected, not re-exported. Unknown legacy keys cannot
be classified until their definitions/migrations are supplied. Once a key is
declared secret, even a failed migration redacts its cached value and blocks later
plaintext writes. Explicit replacement/reset can repair an invalid Keychain item.

Without Apple Security, the default backend contains no readable secret values;
registration and ordinary JSON settings work, but every secret write/delete
explicitly throws `secretStorageUnavailable`. There is no production memory store
masquerading as persistence. A locked/unavailable Apple Keychain likewise produces
a real error. Extensions that need only normal settings should register only their
required normal definitions; sharing JSON does not grant Keychain access.

## Coordinator insertion and timing

1. Resolve the application's **existing** app-group/account base directory. Before
   any native consumers/policies or UI start, configure the selected file, then
   register the connected domain definitions. These APIs do synchronous I/O; use
   an application bootstrap worker where needed and wait before starting consumers.
   Configure selects a file; it does not automatically move data from another URL.
2. The coordinator's `registerDomains` builds the definition list. Core and root
   never reference `AppearanceFeatures`, `ChatFeatures`, `PrivacyFeatures`,
   `AIFeatures` or `ToolsFeatures`. In the main app, registering the full connected
   list together also makes legacy secret classification available before writes.
3. Install the AccountContext factory on bootstrap, including an error state so
   a failed store is visible. Existing root/integrations own and update contexts.

```swift
// Composition imports: ExteralessCore, AccountContext, TelegramUI as appropriate.
let settingsURL = existingBaseURL.appendingPathComponent("exteraless", isDirectory: true)
    .appendingPathComponent("client-settings.json")
try ClientSettings.shared.configure(storageURL: settingsURL)
try ClientSettings.shared.register(connectedDomainDefinitions)

// On main; also install this when configuration failed, to expose lastError.
ExteralessSettingsEntry.setControllerFactory { context in
    exteralessSettingsController(context: context)
}
```

For `PeerInfoSettingsItems.swift`, after the existing plugin entry (advanced row
id 7), the inspected source leaves id 8 free. Existing imports already include
AccountContext. Coordinator applies:

```swift
if ExteralessSettingsEntry.isAvailable {
    items[.advanced]!.append(PeerInfoScreenDisclosureItem(
        id: 8,
        text: ExteralessSettingsLocalization.text("Title", fallback: "Exteraless Settings"),
        icon: PresentationResourcesSettings.appearance,
        action: {
            guard let parent = interaction.getController(),
                  let controller = ExteralessSettingsEntry.makeController(context: context) else { return }
            parent.push(controller)
        }
    ))
}
```

`ExteralessSettingsEntry` has no Core/TelegramUI dependency; its factory is invoked
on main and outside its lock. It also supplies the `Exteraless` strings-table seam
with explicit English fallbacks.

## Domain actions / native UI behavior

Exact contract:

```swift
ExteralessSettingsAction(id: title: section: action:)
// action: @MainActor (AccountContext, ViewController) -> Void
ExteralessSettingsUI.registerActions([action]) // @MainActor, merge/replace by id
ExteralessSettingsUI.unregisterActions(ids: Set<String>)
@MainActor exteralessSettingsController(context:) -> ViewController
@MainActor exteralessSettingsController(context:settings:) -> ViewController // fixture
```

Only registered definitions/actions produce feature rows. Sections are derived
from their section labels; no prefilled inert feature catalogue. Switches,
enum selectors, validated numeric/text/JSON editors and bounded stepped sliders
use the real store. Scalars without a suitable finite slider range remain editable
numerically. Secret replacement uses a secure text field; secure structured data
accepts replacement JSON, while domain actions can provide richer editors.

Mutations are validated before store calls, performed off-main, and re-queried
after completion or failure. All pages observe all invalidations, including
dependent values changed by native consumers. Dynamic action registration and
PresentationData updates re-render labels. Theme list colors, chosen Telegram
font size, system accessibility size, automatic multiline cell height, VoiceOver
controls/reset actions, keyboard insets and reserved-corner side bands are used.
Long-press/reset removes one override; the root share button exports redacted JSON.

## Build handoff

Build-agent owns all BUILD/MODULE edits. Add/verify:

- `//third-party/exteraless:ExteralessCore`, including the five Core sources here
  and the separately owned domain files. Foundation; conditional Security on
  Apple and Darwin/Glibc for filesystem primitives. Swift 6, no external packages.
- TelegramUI: the two `ExteralessClient/ExteralessSettings*.swift` files and Core
  dependency. Other imports already match native list infrastructure:
  AccountContext, AsyncDisplayKit, Display, ItemListUI, SwiftSignalKit,
  TelegramPresentationData, UIKit, Foundation.
- AccountContext: `Sources/ExteralessSettingsEntry.swift`; its existing Display
  and Foundation dependencies suffice.
- No changes from this agent to AppDelegate, PeerInfo, BUILD/MODULE, PluginHost,
  CPython/C or domain implementation files.

## Verification / remaining evidence

Meaningful XCTest fixtures cover persistence/recreation and coherent initial
snapshots; non-finite/nested JSON, wrong types, enums, ranges and steps; corrupt and
future documents; failed configure targeting; unknown keys/metadata; legacy and
key-rename migrations; concurrent independent stores; explicit reload; callbacks
that re-enter, cancellation and deinit; readers during blocked secret I/O; secret
round-trip/redaction/export/reset; plaintext migration failures; backend error
sanitization; Linux explicit secret-write failure with working normal settings.
Fixtures use only temporary files and injected secrets, with bounded waits (1–5s).
They also pin failed secret-upgrade redaction and explicit repair of a corrupt
secure item. There are 15 XCTest methods (the non-Apple case is conditional).

Local bounded source checks passed: all 11 owned source/package/handoff files
decode as UTF-8, have no trailing whitespace/NULs, and Swift delimiters balance;
the five Core files import only Foundation/Security/Darwin/Glibc. This is a source
sanity check, not a Swift compile or XCTest result.

**Not run:** Swift/XCTest, UIKit typecheck, simulator/device frames. `Get-Command
swift, swiftc` confirmed neither executable is available in this Windows session.
There is no XcodeBuildMCP/device tool here. Real CI belongs to the coordinator after
stitching. After its build, a bounded Linux test invocation is:

```sh
timeout 30s swift test --package-path swift/ExteralessCore --skip-build --filter ClientSettingsTests
```

### Frame expectations, specified before recording

Record the real entry → root → selector/editor → back in light/dark and large
accessibility type, plus empty registry, storage failure and one custom domain
screen. Root must use the current Telegram background/navigation/list colors with
no white flash; titles/explanations/footers wrap without cutting off controls.
Native navigation should match the existing grouped-list push/pop (roughly 0.3s),
with no additional row movement or overshoot introduced by this root.

Switches show the confirmed value during persistence and the new value on success;
failure leaves the actual stored value and a visible error. Slider preview tracks
the finger, commits only at gesture end, and errors re-query the confirmed value.
VoiceOver increments one declared step. A secret row/editor must never display a
stored secret; opening it shows an empty secure replacement field. Keyboard
appearance and insets must keep the edited caret visible; theme/font refresh must
preserve the draft and selection. Dependent values and custom-action titles must
refresh without leaving/reopening the screen. Exported text contains neither
secret values nor secret keys. Verify iPad share-popover anchoring, landscape and
reserved-corner side bands as well. No visual pass is claimed without labelled
frame evidence per AGENTS.md.
