# Trust secondary permissions — S1 / S2 / S3

Date: 2026-11-16.

**Consumer fixes are applied. The small Runtime/BUILD coordinator patch is ready
and still required for production file-share classification. Native execution is
pending.** This report addresses the three counterexamples in the read-only
[`reviews/plugin-trust-level-source-closure.md`](reviews/plugin-trust-level-source-closure.md).
It does not replace that independent review or the historical APPLIED manifest.

## Applied consumer changes

### S1 — complete TL media dependencies

`PluginTLBridgeExtension` classifies every actual media path before ticket
admission: one resource for file `sendMedia`/`editMedia`, all resources for an album,
and none for text-only operations. The captured predicate requires UI and
`messages.send`, plus `files` if **any** resource is external. This decision uses
canonical native ownership, independently of current grants.

The immutable resources travel in the already-existing scheduled start closures.
Albums prepare those admitted resources instead of looking up the original paths
again. The full ticket predicate is the existing `nativeCancellation`/preparation
guard and the callback-completion guard; no fresh `files` grant is selected after
an await. Permission retirement still uses the original registry completion and
owner-FIFO release path, including refused-release backpressure.

`PluginTLMediaPreparation` revalidates the admitted canonical URL on its serial IO
queue, checks the full predicate before opening and on every bounded read, and
keeps existing size/type/photo/AVFoundation limits. Former main-thread `mediaURL`
lookups after preparation are removed: the prepared bytes and original ticket
remain authoritative. Own-root media and text retain their narrower requirements.

### S2 — link tap owns an intents epoch

The actual rendered-link `openLink` consumer now captures `{ui, intents}` at the
tap's admission. Its retained effect carries that predicate through URL
interception and the deferred main continuation. The continuation checks the
retained effect before the OS opener; regrant cannot revive the old tap.

The parent alert/page keeps its original UI-only presentation lease. Existing
owner/account/revision/visibility checks remain, and budget credit survives until
the opener finishes or the deferred continuation is discarded. Optional internal
interception/opener arguments allow the same consumer to be exercised by a
loginless UIKit fixture without opening a real URL. Production defaults still use
`NativeServiceOpenHooks` and `UIApplication.open`.

### S3 — share ownership precedes grants and queueing

`admitModelResources` is called by actual `uiPresent` dispatch on the C caller.
It classifies all share paths, derives `{ui, intents, [files]}`, captures **one**
irreversible predicate, and rejects missing permissions before invoking the legacy
resolver, checking file availability, accepting callback leases, or queueing the
presentation. The same predicate is passed to both the retained effect and the
presentation lease; existing deliveries retain it as well.

The queued share receives the admitted resource values. `presentShare` consumes
only those canonical targets, replacing its previous main-thread grant-dependent
resolver with target/regular-file revalidation. Canonical URL memory is included
in retained-effect accounting. This moves ownership/resolver work earlier; it adds
no new main-thread file-read operation. Completion also checks the presentation's
full predicate. Removing `files` retires external-file shares, while own-root
shares do not depend on an unrelated `files` grant.

## Shared classifier and compatibility

New `swift/PluginHost/Sources/PluginHost/PluginResourcePath.swift` provides the same
canonical path-component membership rule used by the previous consumers:
strict descendants of native files/cache roots are owned; sibling prefixes and
symlink escapes are external. It preserves the 4096-byte/absolute/NUL-free path
validation and never opens or reads resource contents. TL's existing rejection of
double-slash paths remains in its model parser. A captured canonical target that
later resolves elsewhere is rejected rather than reclassified under a new epoch.

`PluginUIShareFiles.swift` retains its original Foundation-only API/source; its
resolver is now invoked before queueing, after complete permission capture. The
new classifier is shared by TL and the native UI classification binding.
Host, trust levels, consent storage and permission-model logic were not rewritten.

MCA17's three-argument `uiUpdate`, settings snapshot requirement, update reservation
and completion/ACK paths remain in the shared UI bridge. Their candidate effects
still use UI permission; active share models already reject `uiUpdate` through
the existing model contract. The settings event metadata and reserved-credit
implementation are owned by the Custom remediation. Concurrent coordinated
NativeElyx Host additions were retained.

## Required coordinator integration

[`plugin-trust-secondary-permissions-coordinator.patch`](plugin-trust-secondary-permissions-coordinator.patch)
contains three exact-context hunks, in OpenCode patch format:

1. Supply `classifyShareFile` in `ExteralessPluginRuntime` using this plugin's
   native files/cache roots and `PluginResourcePath`. The existing resolver and
   controlled callback remain. Without this binding file shares fail explicitly
   as unavailable; text/URL-only shares do not require a classifier.
2. Include the new UIKit fixture in `ClientHarnessSDKFollowupSources`.
3. Add `PluginTLSecondaryPermissionTests.swift` to `ExteralessTLModelTestsLib`,
   preserving the existing TL/edit/Elyx test entries.

The patch matches the current coordinated source, including MCA17 and the native
Elyx Runtime handler. Runtime and BUILD files were not edited by this task because
their coordinator/tooling owners are active. The two new optional native UI
constructor inputs are `classifyShareFile` and the default-main
`schedulePresentation` seam, alongside the existing permission admission input.
No Python SDK facade or owner-token format was introduced.

PluginHost's source and SwiftPM test globs already include the new classifier and
its tests. UI production sources are also globbed. The fixture is compiled only
with `PLUGIN_TRUST_SECONDARY_UI_FIXTURE`; a coordinator-owned harness supplies its
existing loginless `AccountContext` and visible `ViewController`:

```swift
try await PluginTrustSecondaryUIFixture.run(context: context, presenter: presenter)
```

## Prepared regression evidence

**Not executed in this Windows session:**

* `PluginResourcePathTests`: ownership without opening a nonexistent resource,
  sibling-prefix and path-bound rejection, canonical symlink ownership and
  post-admission retarget rejection. The symlink case is excluded on Windows.
* Three `PluginTLSecondaryPermissionTests`: real document/edit/album request
  dispatch with missing files denied before queueing; held actual native starts,
  remove-only-files/regrant, real preparation reader rejecting before an absent
  file is inspected, no account resolution/body delivery, and false-release
  ownership retention; own-root actual reads with files removed and completion
  callback backpressure followed by exactly one release. Canned Host workers
  provide actual captured `CallbackOwner` values, not fabricated owner IDs.
* `PluginTrustSecondaryUIFixture`: actual `uiPresent` dispatch and visible UIKit
  alert; actual `openLink` held across downgrade/regrant with UI-only parent
  preservation, false-interception control and dropped-continuation budget refund;
  external share rejection before the resolver, held presentation/false-cleanup
  retention, visible external-sheet retirement and queued delivery revocation,
  and real own-root sheet/cancel completion without a files grant. Only URL
  interception/OS opening and callback transport are controlled; no external URL
  is opened or account/network operation submitted.

Native waits are bounded to two seconds, fake Host stop to one second; every case
uses tiny disposable local fixture files and is designed for the requested
30-second bound. These fixtures exercise production consumers, not a mirrored
permission-policy implementation. UIKit appearance/frame evidence and native
compiler/test results remain pending.

## Source validation and post-change hashes

37 bounded source assertions passed, including the three consumer routes, original
permission-model/review/manifest bytes, classifier path boundaries, MCA17 markers,
and dry application of the coordinator hunks. Scoped `git diff --check` passed.
All commands used timeouts of at most 30 seconds. The Host file changed concurrently
through coordinated NativeElyx target/descriptor/verified-load integration; it was
read for continuity and not edited here. No CI was queried/launched, and no native
fixture, real engine, external plugin, real account or network operation was run.

Exact SHA-256 of worktree bytes after these edits (the UI bridge includes the
coordinator's MCA17 changes):

| File | SHA-256 |
| --- | --- |
| `swift/PluginHost/Sources/PluginHost/PluginResourcePath.swift` | `fd68d73978d46702f7a1a9e3e08f65e2d20189c0280c6a12b32b92436a6b0e45` |
| `swift/PluginHost/Tests/PluginHostTests/PluginResourcePathTests.swift` | `9762c3cff2bb68ff37daa6c629402db42337dd4afe05e1a3da6eeb24535df4ee` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift` | `f98ce7dce0500a5e322e68b2fecdbf01d5d1a5cecb98712b4b12f57613bc1583` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift` | `1610362e479d19d5f37737cc7f46bf105defd432cce84d58b078ff5f307b27cf` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift` | `cd5704a1efe1b3f532f128273a3707c4cb92baa7fce4e3c73d36827021cf9e9e` |
| `telegram-ios/submodules/TelegramUI/Tests/PluginTLSecondaryPermissionTests.swift` | `13f05fce3e6c053bec2ee26a40a61b09ccbce59f0c220ac7b566e9ca82752c93` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginTrustSecondaryUIFixture.swift` | `0b11364ca436461cebbb1c0b26567f8a476042c4b7064efb18afb742bfa67076` |
| `docs/wave-2/plugin-trust-secondary-permissions-coordinator.patch` | `209a5491435ee927ef488a6fdac3c3f072b65ffcdd578527e0eed0eed32fb57c` |

## Coordinator APPLIED

The three Runtime/BUILD hunks are applied. Production UI construction now supplies
the shared classifier using native-owned per-plugin roots. The native source
groups include the three TL regressions and loginless UI fixture. MCA ACK/FIFO,
controlled callbacks and native Elyx ingress remain present. Independent S1–S3
follow-up and actual Apple execution are still pending.
