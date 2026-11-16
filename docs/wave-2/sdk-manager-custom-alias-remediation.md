# Manager Custom widgets and original settings aliases

## Status / scope

Owned implementation for the two P2 routes in `module-routes/plugins.md:71–90` is prepared. **Production integration still requires the coordinator patch below; native compilation/rendering is not claimed.**

- Manager reads now have a native `PluginSettingsPageLease` and an isolated SDK callback snapshot. `Custom(view=…)`, `Custom(item=…)`, and `Custom(factory=SimpleSettingFactory(…))` materialize through the original SDK builder on the owner worker.
- Own `PluginsController.openPluginSettings(id, target)` resolves the exact original `link_alias` or `key` in the current original settings JSON. Manager and portable routes use the same matching/error contract and serializer row identity space.
- Local verification: **8 new bounded Python cases + 2 existing UI/settings cases passed**. Each child has a 20-second timeout. These execute the original SDK and actual Python adapter against a native-service **wire recorder**, not the C extension or UIKit.
- Prepared: **4 Host lifecycle/worker tests** (canned engine, actual Host) and **5 native renderer/model/gate tests** (actual `PluginUIWidgetView`/container/cell/resources). `swiftc` is unavailable on this Windows worker; neither set was executed here.

Initial implementation checkpoint: working tree at `e766b61e241598dccc8017bcd205bfe8b7c792ce`. Other owners were editing archive/trust/Runtime areas concurrently. Hashes below pin the relevant input/postimage files, not a claim that all working-tree changes belong to this task.

## Actual call paths

### Manager read, materialization, release

1. `PluginSettingsController.loadPluginSettings` captures the existing read invocation before any async hop, allocates a unique `PluginSettingsPageLease(owner, account)`, and carries it in `PluginSettingsPageExecution.current` through `actions.settings`.
2. The coordinator Runtime hunk forwards that **same** lease to `Host.settingsJSON(page:)`. The existing expected-owner resolver, event queue/batch cancellation and actual worker predicate stay in the path. `CreateSettingsPayload` carries the native lease; only its opaque UUID and the existing JSON account payload enter Python.
3. `PluginScriptBuilder` selects `_ui.read_settings_page_json`. That function calls the original `dispatch_json("create_settings", …)` / `plugin_loader.get_settings_json` against an isolated shallow `PluginRecord` copy, restoring the original registry in `finally`.
4. `_SettingsPage.prepare` uses `plugin_loader._build_custom_view` (view → item → factory). `SimpleSettingFactory.build_view` retains its original prefix binding and create/bind delegates. No factory runs in Foundation decode, UIImage loading, a UIKit event closure, or layout.
5. A Manager Custom row retains its original `row_id`/alias/subpage metadata and carries `widget_json`, or a visible `custom_error`. The native document uses the existing `PluginUIWidget.parse`; `PluginUIManagerCustomCell` hosts the shipping `PluginUIWidgetView` and `PluginUIWidgetContainer`. UIImage/font resolution happens on main after the guarded decode.
6. Read cancellation/error, discarded document, refresh/replacement, page dismissal, account replacement, and unload retire the snapshot. `close()` synchronously revokes native page work, then schedules `_ui.release_settings_page_json` on the **captured owner** FIFO. If close wins before worker admission, materialization is denied; if after entry, cleanup is queued behind that build. Unload also disposes the zero-C-handle SDK lease.

Host still returns/cache-forwards an opaque JSON **String**. PluginHost has no UIKit dependency. The dynamic schema cache remains unproven (`recordDynamic`; no new immutable-schema evidence or backup authority).

### Callback ownership and arguments

- Original `cb_` / `lc_` IDs stay in the page's copied SDK ledger. They are not positive C handle numbers.
- Nested portable Widget callbacks are lifted into page-local `cw_<page UUID>_<entry>` string IDs. A native event names its row, widget, event kind and string callback. Python verifies the exact tuple in that snapshot, never looks up the latest page's IDs.
- Callbacks are removed from the model during the existing `Widget.to_model()` deep-copy, then restored by identity. A bound method retains its actual plugin instance; it cannot be silently rebound to a deep-copied plugin.
- `Custom.on_click` / `on_long_click` receive their original portable Widget (or no argument for a zero-argument callback), so a root callback can read its nested edited values. Ordinary Text clicks keep the SDK's optional `None` argument. Ordinary setting changes retain **persist, then original callback** semantics; exceptions do not undo a completed write.
- A nested Widget's `model["callback"]` accepts a callable or a string ID already owned by this SDK snapshot; value controls receive the value, click controls the Widget, using the original optional-argument helper. `long_callback_id` follows the same page ownership. Unknown strings and non-callables produce a materialization error, not C coercion.
- Native inline changes use one bounded FIFO (`PluginUIManagerWidgetEvents`), captured action invocations, and the existing Runtime click path. Host rechecks page, owner, account/UI permission and action predicate on the actual worker. Delayed effects retain the same revocation guard. Refresh/cancel cannot turn an old closure into a newly captured permit.
- Inline value changes update their local native draft and owner-worker Widget state; they do not call `create_settings` for every keystroke. Rebuilding the settings schema remains an explicit refresh/action refresh operation.

Factory-only Android `CustomSetting.Factory`/`UItem` facets and arbitrary Android Views remain explicitly unavailable. The implementation consumes the original Python `build_view` contract; it does not invent general Java/UIView proxy support or silently invoke unknown factory delegates on main.

### Exact target contract

`None`/`nil` selects the ordinary root. Non-null target must be a nonempty string, no NUL, at most **256 UTF-8 bytes**. Matching is exact (no trimming/case folding/Unicode normalization) against **either** original `link_alias` **or** `key`, counted once per matching row across the current document.

| Result | Python | Manager |
|---|---|---|
| One row | `{pagePath: [ancestor row_id…], rowId}` | `PluginSettingsTarget` |
| Invalid input | `SettingsTargetError.code == "invalid"` | `.invalid` |
| Too long | `… == "tooLong"` | `.tooLong` |
| No match | `… == "unknown"` | `.unknown` |
| Multiple matching rows | `… == "ambiguous"` | `.ambiguous` |

Manager's resolver compares UTF-8 sequences because Swift String equality otherwise folds canonical Unicode equivalents. Portable preparation now uses original `row_id` as `id`; an alias is a lookup key, not a second identity system. `pagePath` selects the containing native page and `targetRowId` focuses the actual row after visibility/permission checks, without invoking its callback.

Portable opening captures `uiActiveFragment` and its account before materialization; `sourceId` reaches native admission. Refresh retains that source and its presentation lease. A rejected update/unknown refreshed alias disposes only the candidate snapshot; the old page keeps its original callback targets. Cross-plugin calls fail the existing `check_plugin` before a settings read.

No existing native `p`/`s` plugin-setting URL handler was found in the inspected TelegramUI/native routing sources. This change supplies the requested own-plugin facade and native resolver, not a new external URL handler.

## Bounds

- Original Manager response/cached String: **1 MiB**, **1,000 SDK rows**, **16 subpage levels**.
- Custom portable widgets: **512 nodes**, **8 levels**, cycle/duplicate Widget-ID rejection; native parser enforces the existing field/resource/value/layout bounds. No Android `__handle__` object is rendered as a widget.
- Page callback snapshot: **128 entries**, using the existing SDK lease-count/generation budget; Manager snapshots allocate **zero C callback handles**.
- Inline native event FIFO: **128 entries / 512 KiB including the in-flight event**. Host event JSON is bounded independently. Cleanup has no permission to enter a replacement owner.
- Native resource errors close the rejected page; Python materialization errors produce an honest error row and release that row's callback/view/factory references.

## Coordinator patch — required joins, not applied by this author

`PluginManagerController`'s existing settings row (`:363–373`) already constructs the modified `PluginSettingsController`; it needs no extra API or grant edit for these two changes. Its trust/grant UI hunk remains coordinator/owner work.

The patch below uses the `functions.patch` format. It covers:

1. Runtime read forwarding and synchronous Manager page revocation at context replacement/clear/terminate.
2. Portable `targetRowId` validation and actual content-controller focus helper calls. These two existing PluginUI files were outside the author's direct-edit allowlist.
3. The existing harness's one-argument read join, plus a **new**, separate native fixture source group. It does not rewrite historical receipt/count/frame files.

Shared preimage raw SHA-256:

| Path | SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift` | `ba0330321b86bb8a112193d50fc8b5368b5335c9065230fd8402677956baf1ad` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginManagerController.swift` | `1c27e99a96669e029088558b0ecb638eb22eb7fcd3e77aeb6d9422a113ae9271` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift` | `934e219922091da4b78aba3cc5a13f0e6ee09a9fdea60afa845baf9b4e357606` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIContentController.swift` | `64976b4824475be25401d6260a3bf0ef0f33de73cbf5857e8b091f3103740cb3` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift` | `ee8be8a5843bf90ba831b673bec760b02527522004b7251117173d3dd8379d8b` |
| `telegram-ios/submodules/TelegramUI/BUILD` | `3dc55c23a2ff7ce9e1d449c527874e9e6ac96a238534f2c7e1dd4ff620687741` |

```patch
*** Begin Patch
*** Update File: telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift
@@
     public func update(context: AccountContext) {
         guard !terminating, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
+        if currentContext !== context { PluginUIManagerSettingsLifetimes.closeAll() }
         settingsActionAuthority?.prepareContextChange(to: context)
@@
     public func clearContext() {
+        PluginUIManagerSettingsLifetimes.closeAll()
         startupScope = UUID()
@@
             json = try await host.settingsJSON(id: id, account: account, expectedOwner: owner,
-                shouldExecute: { read.isCurrent })
+                shouldExecute: { read.isCurrent }, page: PluginSettingsPageExecution.current)
@@
         startupContinuation?.retire()
+        PluginUIManagerSettingsLifetimes.closeAll()
         settingsActionAuthority?.clearContext()
*** Update File: telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift
@@
-        case .settings, .page: fields = ["rows", "pagePath", "subtitle", "cancelable", "icon"]
+        case .settings, .page: fields = ["rows", "pagePath", "targetRowId", "subtitle", "cancelable", "icon"]
@@
         if let source = try object.uiString("sourceId", limit: 64) {
+            guard let id = UUID(uuidString: source) else { throw PluginUIFailure.invalidHandle("Invalid native fragment id") }
+            self.sourceId = id
+        } else { self.sourceId = nil }
+        if let target = try object.uiString("targetRowId", limit: 256) {
+            guard kind == .settings, object["rows"] != nil, !target.isEmpty, target.utf8.count <= 256 else {
+                throw PluginUIFailure.malformed("SettingsTarget.invalid")
+            }
+            var page = self.rows
+            for id in self.pagePath {
+                guard let next = PluginUIWidget.find(id, in: page)?.subpage else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
+                page = next
+            }
+            guard PluginUIWidget.find(target, in: page) != nil else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
+        }
-            guard let id = UUID(uuidString: source) else { throw PluginUIFailure.invalidHandle("Invalid native fragment id") }
-            self.sourceId = id
-        } else { self.sourceId = nil }
         if kind == .share && self.text.isEmpty && self.files.isEmpty && self.url == nil { throw PluginUIFailure.malformed("Share requires text, a URL or files") }
*** Update File: telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIContentController.swift
@@
     private var inlineError: String?
+    private let settingsTargetFocus = PluginUISettingsTargetFocus()
@@
         self.armTimer()
+        self.revealSettingsTarget()
     }

     override func viewWillDisappear(_ animated: Bool) {
@@
         self.scrollView.layoutIfNeeded()
         self.revealInput()
+        self.revealSettingsTarget()
     }

+    private func revealSettingsTarget() {
+        self.settingsTargetFocus.reveal(model: self.model, revision: self.revision, pagePath: self.pagePath,
+            scrollView: self.scrollView, widgets: self.widgetViews(), permitted: !self.isClosing && self.canAct(self.revision))
+    }
+
     private func page() -> (title: String?, rows: [PluginUIWidget]) {
*** Update File: telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift
@@
                 let json = try await host.settingsJSON(id: id, account: read.account, expectedOwner: read.owner,
-                    shouldExecute: { read.isCurrent })
+                    shouldExecute: { read.isCurrent }, page: PluginSettingsPageExecution.current)
*** Update File: telegram-ios/submodules/TelegramUI/BUILD
@@
-swift_library(
-    name = "TelegramUI",
+filegroup(
+    name = "ExteralessManagerCustomAliasSources",
+    srcs = [
+        "Sources/Exteraless/PluginSettingsModel.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIModel.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIStyleModel.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIViews.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIWidgetContainer.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIResources.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUISettingsActionGate.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUISettingsDocument.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIManagerSettingsDocument.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIManagerCustomCell.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUISettingsTargetFocus.swift",
+    ],
+    visibility = ["//Tests/ManagerCustomAlias:__pkg__"],
+)
+
+swift_library(
+    name = "TelegramUI",
     module_name = "TelegramUI",
*** End Patch
```

## Verification and remaining native acceptance

Executed locally:

```text
python -B -m pytest -p no:cacheprovider -q tools/compat/tests/test_sdk_manager_custom_alias.py tools/compat/tests/test_sdk_adapter_wave2.py -k "manager_custom_alias or settings_menu or ui"
10 passed, 18 deselected in 5.59s (fresh -I -S -B children; 20s hard timeout each)
```

The new tests use only the owned `fixtures/ios_runtime/manager_custom_alias.plugin`; they assert actual original SDK call bodies, restored global ledger identities, nested/bound-method callback identity and arguments, no C handles for Manager, weak-reference release, stale owner/wrong worker rejection, key/alias/Unicode/duplicate/unknown/length cases, failed-update rollback and bounded model rejection.

Prepared native checks:

- `swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift`: batch-retained read effect; cancelled running read cleanup **after** late worker completion; action predicate checked only on the worker (off-worker guard deliberately stays true); revoked effect; owner/account mismatch and exactly-once release. Canned engine responses are not CPython execution.
- `telegram-ios/Tests/ManagerCustomAlias/ManagerCustomAliasNativeTests.swift`: exact native alias resolution; actual nested UITextField event/rollback under production page gates; resource and row/widget depth/count rejection; actual scroll-to-target helper with a UIWindow. Only fixture label localization is substituted. Target: `//Tests/ManagerCustomAlias:ManagerCustomAliasTests`, after the shared source-group/model joins above. Keep the owned native case runner at ≤30 seconds per case.

Before recording the native Manager entry and own-plugin targeted entry, expected frames are: real nested native controls inside the grouped Custom row; no placeholder canvas, duplicated content or clipped text at narrow/accessibility sizes; target's containing subpage and row visible without firing its callback; error rows for unsupported Android View/factory results; account/read replacement cannot display a newly activated old control. Record opening/refresh/dismissal, light/dark and large text, and inspect indexed/timestamped frames. No recording was performed on this worker.

The historical 147-ID map and HNS-F01–04 source closure, and the supplied 36-target/410-test/8-frame native cohort, retain their original checkpoints/scopes. They are not execution receipts for this new code. No new native/full-app/CPython-green claim is made here.

## Source fingerprints

Original SDK inputs (raw bytes, untouched):

- `python/sdk/ui/settings.py`: `483154a1355c8476f8fff60dbf9975e5b4f7cb088d62d822071c6c7b0c5000e3`
- `python/sdk/extera_utils/plugin_loader.py`: `c90134bde58559d675ffeff313eecd4223f39d60edbe0992137b41461b6547f5`

Read-only lease/renderer inputs:

| Path | Raw SHA-256 |
|---|---|
| `python/exteraless_runtime/_callbacks.py` | `70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481` |
| `swift/PluginHost/Sources/PluginHost/PluginEventExecution.swift` | `882de607740cfd3eca62cd11d564519c987498bcd8fd862194dc21f1b6e73707` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIViews.swift` | `cd418572e82baa54cc78cc76d9ca6a54ca2b71211ed4da3e58a6c28a40ac9b20` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIWidgetContainer.swift` | `fa67d1eefbd1cff56840af38d67b8ed2cc6aa58dfe2d1c98f9708ee8af01e1e2` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIResources.swift` | `b2c2fee2a8c61c80a038378d873215380537261bd013f751535b8461cb8512b7` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsActionGate.swift` | `dc0f894d909340d48ffa227ae7e68721ddc01f53cab1a598f6c9fc89496024fb` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsActionInvocation.swift` | `788f8f8603b28e5527b67538b39f8fd3f7c398af0f6f9b8bd88b1727ed8ada98` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsReadInvocation.swift` | `c6cd08205022e3d0d6fe3a4a3bfa6aa94b226022b60d8feb13fecac7ae2e9707` |

Owned implementation/test file postimages (raw SHA-256; `PluginHost.swift` also contains the pre-existing concurrent archive-owner edits):

```json
{
  "python/exteraless_runtime/_ui.py": "6cd1ff47408cade40aa6a99b19c0319bdde291990182bf245aad21708ebbf57f",
  "python/exteraless_runtime/_facades.py": "c9a5b7c0861d07441746d3967e119fb0fe6efe38d4b560714970b6fa4d3f12bf",
  "swift/PluginHost/Sources/PluginHost/PluginHost.swift": "7da9cc444d453201a88f271683d9eaa706170c6059d515c4debf4db3f99be30f",
  "swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift": "a7f5ce2b5fd5495a505a548504a40c9cf8f83fbbfcbd95d22d727da5360dec5b",
  "swift/PluginHost/Sources/PluginHost/PluginSettingsPageLease.swift": "d607bf036b27d3af74de54a0fce1f1614f7bdd73ab940d443feb074df0d5e19c",
  "swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift": "083f795b3e8f246b7d517ef82e57eb09a8cce8f409c0ba0e133b11ac1b853269",
  "telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsModel.swift": "1561d1dd79fa407818f2c23ea9f2fdb8ed6781d86c49c283be348ce41c47cfd7",
  "telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift": "18c11359debb3c72176bf4a939b158532a60cca4dcfe3529a4e6ed9b66cd1285",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerSettingsDocument.swift": "1cd3f90853801580581cf49497082541112a0e8a6419d50a266fa87a6b02b143",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerCustomCell.swift": "da8e69a506ffa0aec8dbe29d641dc7a9fb5e049e3f3877b6d23840899ab3e610",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerSettingsLifetimes.swift": "30a0411f84065f65bbf28ae7352756cbf19716394221fdf14179e78f02e8b2b4",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerWidgetEvents.swift": "731ef03db3afef8345b9c563a2cc9bfd8ad2de61f3cc26ef959d8e892b1ef899",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsTargetFocus.swift": "23a0fef3a408fb003e33f3b172a791b08a0225eaaec3775d430ab52eb1d36fba",
  "telegram-ios/Tests/ManagerCustomAlias/BUILD": "d35b6a7a5295c2aeab87afd025ab5a86d12a245100d68c898a8af5e0701bf3a4",
  "telegram-ios/Tests/ManagerCustomAlias/ManagerCustomAliasNativeTests.swift": "fa3169d01778edc0e189f73b6fff3d192f3ee9ba1f81f125fe8e0c470a7758bb",
  "tools/compat/tests/test_sdk_manager_custom_alias.py": "964ab285a50df1a2efd7d76fa22a8376976a61cf4718ca88a68b964fc2999792",
  "tools/compat/tests/fixtures/ios_runtime/manager_custom_alias.plugin": "77b935dc760fd01b328bfdf519afe334905ac4aca5d29d818199f040346eedd4"
}
```

Read-only source checks passed: Python/new BUILD syntax, original SDK byte pins, native fixture JSON decoding, owned source whitespace and `git diff --check`. All **11 shared hunks** matched uniquely and were applied **in memory only**. Expected LF postimages for the coordinator's five files:

| File | Expected LF SHA-256 after the patch |
|---|---|
| `ExteralessPluginRuntime.swift` | `43938adb9f119b916addacb82bb42bc2954dc7240a340699254b836621dcc816` |
| `PluginUIModel.swift` | `d61ea20efaf8ac9b6c733796fc9eb6ef49e82ca9276bb7d0cc2e9c07d804a7a0` |
| `PluginUIContentController.swift` | `b02ae064c6bab8d90d89b8ac05aee97e486644da41b8e73c7d1228d2a7bc53a4` |
| `ClientHarnessRuntime.swift` | `837f9013330e0986da2046f483061837296fb919ecbf5b730dda6e0a6644e668` |
| `submodules/TelegramUI/BUILD` | `98cb9853672b1bf7f6ea8f45aceda598c43db33fa0c5c664b991e599d8cfc20f` |

These postimages describe the recorded shared preimages plus this patch. Concurrent unrelated owner changes require preserving their hunks and recapturing the resulting full-file hash, not replacing their file with this snapshot.

## Follow-up: MCA-F01 / MCA-F02 only

The independent review `reviews/manager-custom-alias-source-closure.md` is read-only. Its two remaining P2 schedules are the boundary of this follow-up. The previous **11 joins are already applied**; the patch in this section is a new delta, not a request to reapply those joins.

### MCA-F01: admission is not snapshot commit

The review's controlled schedule is preserved in the fixture: S1 is visible, refresh builds S2, `uiUpdate` returns admission while main commit is held, then a captured S1 change executes on the owner. Before this fix the result was `visible_snapshot_version=1 / callback_snapshot_version=2` (review lines 51–77).

The new `_SettingsPresentation` keeps S1's page/model/revision and one candidate S2. It sends a typed third `uiUpdate` argument with the two snapshot IDs and a **unique one-shot completion callback**. Only an ACK from actual native model/revision commit swaps the Python snapshot; synchronous refusal and rejected/cancelled native commit retire S2 and retain S1. The ordinary callback path requires the native-stamped `_uiSettingsSnapshot` and `_uiRevision`; it has no fallback to a replacement page's key/CBID ledger.

The native delta below reserves that completion handle on the original UI owner, performs a revision/snapshot compare at main commit, and queues ACK **then release** through the existing `PluginUIReleaseQueue` / owner dispatcher. A committed S2 does not admit new UI events until ACK/release FIFO admission, so S2 events cannot overtake its ACK. S1 remains actionable while a candidate is merely pending; rejected updates do not close S1. An old event after commit is rejected by the existing revision gate or by the SDK snapshot check, never routed to S2.

ACK uses the existing bounded `_uiTerminal` control lane for the update lease, **not** the special `closed` callback privilege. Its `Delivery.permissionIsCurrent` is the original UI admission predicate. The trust owner's `ControlledCallback` and Runtime wiring are preserved; no `{ true }` permission substitution or regrant recapture is introduced. Main-page retirement owns any still-pending completion handle; a completion already transferred to its own ACK/release retirement is not released twice.

### MCA-F02: one FIFO for inline and root Custom actions

The review's sequence is E1=`a` (held worker), E2=`ab` (accepted but pending in the inline FIFO), root R. The old direct root path submitted R to Host before E2, yielding `E1 → R → E2` and root value `a` (review lines 107–123).

`PluginSettingsController` now enqueues root Custom click/long-click **synchronously at the tap** through `PluginUIManagerWidgetEvents.root`, then its existing mutation/refresh operation awaits that receipt. Both inline and root entries use the same `PluginUIManagerEventFIFO`, so the only execution order is `E1 → E2 → R`. A navigation-only Custom root uses a FIFO barrier. Ordinary Text retains its own `fn(None)`/`fn()` route; Custom retains the original `fn(view)`/`fn()` route, without reconstructing a factory per keystroke.

The FIFO carries captured invocations through the existing TaskLocal/Host path. Close rejects new entries, cancels pending receipts and the captured in-flight invocation, and retains the running item's count/byte credit until its awaited operation unwinds. Limits remain 128 entries / 512 KiB including in-flight work. Inline callback errors still report through the existing error sink and do not pretend that the SDK's preceding value write was rolled back.

### Follow-up coordinator patch (new delta, NOT applied by this author)

`PluginUIBridgeExtension`, `PluginUILifecycle`, `PluginUIModel` and BUILD are shared inputs. Keep the trust owner's future-predicate/control interfaces and any additional grant checks while applying these scoped hunks. No Runtime or ContentController change is required for this delta: the existing `_uiTerminal` reserved-lane classification and `ControlledCallback` transport carry the ACK.

<!-- mca-counterexample-patch:start -->
```patch
*** Begin Patch
*** Update File: telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift
@@
-        case .settings, .page: fields = ["rows", "pagePath", "targetRowId", "subtitle", "cancelable", "icon"]
+        case .settings, .page: fields = ["rows", "pagePath", "targetRowId", "settingsSnapshotId", "subtitle", "cancelable", "icon"]
@@
         if let target = try object.uiString("targetRowId", limit: 256) {
+            guard kind == .settings, object["rows"] != nil, !target.isEmpty, target.utf8.count <= 256 else {
+                throw PluginUIFailure.malformed("SettingsTarget.invalid")
+            }
+            var page = self.rows
+            for id in self.pagePath {
+                guard let next = PluginUIWidget.find(id, in: page)?.subpage else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
+                page = next
+            }
+            guard PluginUIWidget.find(target, in: page) != nil else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
+        }
+        if let snapshot = try object.uiString("settingsSnapshotId", limit: 36) {
+            guard kind == .settings, object["rows"] != nil, UUID(uuidString: snapshot) != nil else {
+                throw PluginUIFailure.malformed("Settings snapshot requires a portable settings model and UUID")
+            }
+        }
-            guard kind == .settings, object["rows"] != nil, !target.isEmpty, target.utf8.count <= 256 else {
-                throw PluginUIFailure.malformed("SettingsTarget.invalid")
-            }
-            var page = self.rows
-            for id in self.pagePath {
-                guard let next = PluginUIWidget.find(id, in: page)?.subpage else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
-                page = next
-            }
-            guard PluginUIWidget.find(target, in: page) != nil else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
-        }
         if kind == .share && self.text.isEmpty && self.files.isEmpty && self.url == nil { throw PluginUIFailure.malformed("Share requires text, a URL or files") }
*** Update File: telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUILifecycle.swift
@@
         var terminalActionDelivered = false
+        var settingsUpdate: PluginUISettingsUpdate?
@@
-    func update(id: UUID, pluginId: String, patch: PluginUIJSON, expectedScope: PluginUIScope? = nil, admission: () throws -> Void = {}) throws -> Entry {
+    func reserveSettingsUpdate(id: UUID, pluginId: String, owner: Owner, patch: PluginUIJSON, request: PluginUIJSON,
+                               expectedScope: PluginUIScope, admission: () throws -> Void) throws -> PluginUISettingsUpdate {
+        return try self.locked {
+            try self.requireScopeLocked(expectedScope)
+            try admission()
+            guard var entry = self.entries[id], entry.owner == owner, entry.state.pluginId == pluginId,
+                  entry.state.scope == self.scope, entry.state.phase != .dismissing, entry.settingsUpdate == nil,
+                  entry.permissionIsCurrent(), case let .presentation(model) = entry.content else {
+                throw PluginUIFailure.invalidHandle("Settings update requires its current, idle presentation owner")
+            }
+            let candidate = try model.applying(patch)
+            let update = try PluginUISettingsUpdate(request, previous: model, candidate: candidate, revision: entry.state.revision)
+            guard entry.callbacks.count < 128, !(self.handles[owner] ?? []).contains(update.completion.handle) else {
+                throw PluginUIFailure.invalidHandle("Settings completion must be a unique bounded callback lease")
+            }
+            entry.settingsUpdate = update
+            self.entries[id] = entry
+            self.handles[owner, default: []].insert(update.completion.handle)
+            return update
+        }
+    }
+
+    /// Settles only the reserved update. Failure before commit leaves S1's model,
+    /// revision, visibility and callbacks intact. Completion retains its credit
+    /// through the same ACK/release retirement queue as other native controls.
+    func finishSettingsUpdate(id: UUID, updateId: UUID, failure: PluginUIFailure? = nil) -> Retirement? {
+        return self.locked {
+            guard var entry = self.entries[id], var update = entry.settingsUpdate, update.id == updateId,
+                  self.retiring[updateId] == nil else { return nil }
+            let committed = update.committed == true
+            update.committed = committed
+            entry.settingsUpdate = update
+            self.entries[id] = entry
+            var event = entry.state.callbackMetadata
+            event["id"] = .string(id.uuidString)
+            event["event"] = .string("settingsUpdate")
+            event["_uiTerminal"] = .bool(true)
+            event["updateId"] = .string(update.id.uuidString)
+            event["previousSnapshotId"] = .string(update.previousSnapshotId)
+            event["snapshotId"] = .string(update.snapshotId)
+            event["committed"] = .bool(committed)
+            if !committed, let failure {
+                event["error"] = PluginUIFailure(kind: failure.kind, message: String(failure.message.prefix(2048))).json
+            }
+            let delivery = Delivery(owner: entry.owner, handle: update.completion.handle, arguments: .array([.object(event)]),
+                permissionIsCurrent: entry.permissionIsCurrent)
+            let retirement = Retirement(id: update.id, pluginId: entry.state.pluginId, owner: entry.owner,
+                handles: [update.completion.handle], deliveries: [delivery], isMenu: false)
+            self.retiring[update.id] = retirement
+            return retirement
+        }
+    }
+
+    func update(id: UUID, pluginId: String, patch: PluginUIJSON, expectedScope: PluginUIScope? = nil,
+                settingsUpdateId: UUID? = nil, admission: () throws -> Void = {}) throws -> Entry {
@@
             let updated = try model.applying(patch)
+            if model.raw["settingsSnapshotId"] != nil || updated.raw["settingsSnapshotId"] != nil {
+                guard let ticket = entry.settingsUpdate, ticket.id == settingsUpdateId, entry.permissionIsCurrent() else {
+                    throw PluginUIFailure.invalidHandle("Settings snapshots require their reserved native commit")
+                }
+                try ticket.check(previous: model, candidate: updated, revision: entry.state.revision)
+            } else if settingsUpdateId != nil {
+                throw PluginUIFailure.invalidHandle("Unexpected settings update transaction")
+            }
             try updated.validateCallbacks(Set(entry.callbacks.keys))
@@
             entry.content = .presentation(updated)
             entry.state.revision += 1
+            if settingsUpdateId != nil { entry.settingsUpdate?.committed = true }
             self.entries[id] = entry
@@
             guard entry.permissionIsCurrent() else { return (false, nil) }
+            guard entry.settingsUpdate?.committed != true else { return (false, nil) }
             if let key = payload["key"]?.string, let value = payload["value"] {
@@
             self.retiring.removeValue(forKey: id)
+            for presentationId in Array(self.entries.keys) {
+                if self.entries[presentationId]?.owner == owner, self.entries[presentationId]?.settingsUpdate?.id == id {
+                    self.entries[presentationId]?.settingsUpdate = nil
+                }
+            }
             self.handles[owner]?.subtract(retirement.handles)
@@
         for (key, value) in entry.state.callbackMetadata { event[key] = value }
+        event.removeValue(forKey: "_uiSettingsSnapshot")
+        if case let .presentation(model) = entry.content, let snapshot = model.raw["settingsSnapshotId"] {
+            event["_uiSettingsSnapshot"] = snapshot
+        }
         event["id"] = .string(entry.state.id.uuidString)
@@
-        let handles = Set(entry.callbacks.values.map { $0.handle })
+        var handles = Set(entry.callbacks.values.map { $0.handle })
+        if let update = entry.settingsUpdate, self.retiring[update.id] == nil {
+            handles.insert(update.completion.handle)
+        }
         self.history[id] = entry.state
*** Update File: telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift
@@
         case "uiUpdate":
-            try arity(2)
+            guard args.count == 2 || args.count == 3 else { throw PluginUIFailure.malformed("uiUpdate expects model and optional settings transaction") }
@@
             try self.validateAssets(candidate, effect: effect, scope: scope)
             try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
+            let settingsUpdate: PluginUISettingsUpdate?
+            if args.count == 3 {
+                settingsUpdate = try self.leases.reserveSettingsUpdate(id: uuid, pluginId: pluginId, owner: acceptedOwner,
+                    patch: patch, request: args[2], expectedScope: scope,
+                    admission: { try self.validateOrigin(origin, owner: acceptedOwner, execution: execution) })
+            } else {
+                guard previousModel.raw["settingsSnapshotId"] == nil else {
+                    throw PluginUIFailure.invalidHandle("Settings snapshot update requires a native completion lease")
+                }
+                settingsUpdate = nil
+            }
             // No committed model/revision is changed on the C worker. A revoked
@@
                 self.applyUpdate(id: uuid, pluginId: pluginId, owner: acceptedOwner, scope: scope,
-                    patch: patch, origin: origin, execution: execution, effect: effect)
+                    patch: patch, origin: origin, execution: execution, effect: effect, settingsUpdateId: settingsUpdate?.id)
             }
-            return .null
+            return settingsUpdate.map { .object(["id": .string($0.id.uuidString)]) } ?? .null
         case "uiState":
@@
     @MainActor private func applyUpdate(id: UUID, pluginId: String, owner: PluginHost.CallbackOwner, scope: PluginUIScope,
                                        patch: PluginUIJSON, origin: PluginUIRequestOrigin, execution: PluginNativeCallLease,
-                                       effect: PluginUIRetainedEffect) {
-        defer { effect.finish() }
+                                       effect: PluginUIRetainedEffect, settingsUpdateId: UUID? = nil) {
+        var rejection: PluginUIFailure? = .invalidHandle("Settings update was revoked before native commit")
+        defer {
+            if let settingsUpdateId, let retirement = self.leases.finishSettingsUpdate(id: id, updateId: settingsUpdateId, failure: rejection) {
+                self.retire(retirement)
+            }
+            effect.finish()
+        }
@@
             _ = try self.leases.update(id: id, pluginId: pluginId, patch: patch, expectedScope: scope,
+                settingsUpdateId: settingsUpdateId,
                 admission: { try self.validateOrigin(origin, owner: owner, execution: execution) })
             self.applyLatest(id: id)
+            rejection = nil
         } catch let failure as PluginUIFailure {
-            if effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
+            rejection = failure
+            if settingsUpdateId == nil, effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
         } catch {
-            if effect.permitsExecution { self.failPresentation(id: id, failure: .unavailable("Native UI update could not be applied")) }
+            let failure = PluginUIFailure.unavailable("Native UI update could not be applied")
+            rejection = failure
+            if settingsUpdateId == nil, effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
@@
         guard let entry = self.leases.entry(id: id), entry.state.revision == revision,
+              entry.settingsUpdate?.committed != true,
               entry.state.phase == .presented, entry.state.isPresented,
*** Update File: telegram-ios/submodules/TelegramUI/BUILD
@@
     name = "ExteralessManagerCustomAliasSources",
     srcs = [
+        "Sources/ExteralessClient/PluginUI/PluginUIManagerEventFIFO.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUISettingsUpdate.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUILifecycle.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIReleaseQueue.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUIMenuModel.swift",
+        "Sources/ExteralessClient/PluginUI/PluginUINavigation.swift",
*** End Patch
```
<!-- mca-counterexample-patch:end -->

### Follow-up verification — 2026-11-16

```text
python -B -m pytest -p no:cacheprovider -q tools/compat/tests/test_sdk_manager_custom_alias.py tools/compat/tests/test_sdk_adapter_wave2.py -k "manager_custom_alias or settings_menu or ui"
15 passed, 18 deselected in 8.66s
```

This is the prior eight owned Python cases, four deferred-refresh schedules, the root callback-arguments case, and two existing SDK/UI cases. Every child remains `-I -S -B`, timeout 20s; the whole local command had a 30s cap. Native services are wire recorders, not C/Swift/UIKit execution.

Exact postfix checks:

- `test_sdk_manager_custom_alias.py`, `deferred_refresh_commit`: after update admission, the recorder still has S1, `presentation.model` is S1, and the captured `known_key` change calls **version 1**, persisting `true`. Only explicit native commit plus owner ACK selects version 2. A forced old event after ACK raises instead of calling the replacement callback.
- `deferred_refresh_reject`: rejected/cancelled commit preserves S1's model, revision and live callbacks; ACK retires the candidate and its one-shot C wrapper. `deferred_refresh_dispose` releases both snapshots and the pending completion exactly once. `deferred_refresh_overlap` rejects a second candidate before another factory build.
- `root_callback_arguments`: after the nested edit, original root click and long-click receive the original Widget containing `ab`; ordinary Text receives `None`; a zero-argument root callback remains zero-argument.
- The existing `test_sdk_adapter_wave2.py` UI recorder now explicitly commits transactional settings updates. Its live builder/inline callback and image-error rollback assertions remain. Old settings callbacks still work after a failed update and during deferred admission. The five presentation callback handles remain identical; the two attempted settings updates allocate two separate completion wrappers, both released, with the successful completion released exactly once. No logical assertion was replaced with a canned result.

Native tests are staged in the **existing** `ManagerCustomAliasNativeTests.swift`: seven new tests after the previous five (12 total). They exercise the shipping FIFO with a held operation (`E1 → E2 → R:ab`), cancellation and retained in-flight credits, both queue bounds, preserved write-before-callback error behavior, native snapshot/ACK/release ordering under backpressure, rejection preserving S1 and its captured permission predicate, and no double release on page retirement. The original four Host tests are retained byte-identically. These native tests were not run here; the shared delta is still coordinator-owned.

`run_remediation_fixture.py` receives only the newly required `PluginUISettingsUpdate.swift` source-list dependency; its 23 scenarios and assertions are retained. The ordinary bounded UI runner and the native UI contract source group already contain that dependency from coordinator work. The new six-source Manager test-group hunk above stages the added tests without replacing existing suites or receipts.

Postfix source references (working-tree lines at this follow-up):

| Route | Source |
|---|---|
| S1 until commit ACK; stamped-event selection | `python/exteraless_runtime/_ui.py:613–733`, `_SettingsPresentation`; `_event_page:647`, `_stage:686`, `_settle:710` |
| Root click/long-click enters FIFO before Task | `PluginSettingsController.swift:435–443,499–519` |
| Shared inline/root executor and JSON contracts | `PluginUIManagerWidgetEvents.swift:19–58` |
| Bounded queue and in-flight close semantics | `PluginUIManagerEventFIFO.swift:51–114` |
| Typed native snapshot/revision/C-completion descriptor | `PluginUISettingsUpdate.swift:6–38` |
| Native commit/future-permission joins | The 17 scoped coordinator hunks above: Model 2, Lifecycle 8, Bridge 6, test source group 1 |

### Follow-up source pins

Raw owned-file SHA-256; the common SDK fixture also contains the pre-existing, unrelated scheduler-owner changes outside its UI regions:

<!-- mca-counterexample-pins:start -->
```json
{
  "python/exteraless_runtime/_ui.py": "301b669e23eeb7388810d699a27f91f16189f6d181070c7851480a417f1f4398",
  "telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift": "3fb7c4c8051f9c2d1e322394199db080984722c7696d7f0057ba23ab2a71d708",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerWidgetEvents.swift": "5ee852a44c138f80f11e3c5c9827aae20f93596bd204c68a8092b75c439b7c02",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerEventFIFO.swift": "7279df92aa04a5c2770f0f604a7ea4db9ee89795e63094bbe1a82e7f8b7292ac",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsUpdate.swift": "38f236d16848b029246f5334ff782b3430a2e5bbf0df88ad85e933866b4ffec7",
  "tools/compat/tests/test_sdk_manager_custom_alias.py": "e057f866789b0fe964d1f4ec54142ab315b0055a382fcd628b1f44b1aea45d2a",
  "tools/compat/tests/test_sdk_adapter_wave2.py": "499eb5f9f31c7ccfa55845133002ae54ad28c38eacd718861675a5ce4f0acece",
  "tools/compat/tests/fixtures/ios_runtime/manager_custom_alias.plugin": "6ad9c7f24f20a3a2768c5b9b51ce65e4e27c7ff88728e92af904f11f6784c188",
  "telegram-ios/Tests/ManagerCustomAlias/ManagerCustomAliasNativeTests.swift": "1213e394f6323c32b8f8d55bd532e2bd551658efe6baefa3be5e0da9948de45e",
  "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_remediation_fixture.py": "2d66c4e0374f31ac62b69a7cc0a84ef0556549067ff60a52d0f3160e9232f398"
}
```
<!-- mca-counterexample-pins:end -->

Shared hashes below deliberately cover only the patch regions: concatenate each file's hunk preimage (context + removed lines) or postimage (context + added lines), in patch order, UTF-8/LF with final LF per hunk. Unrelated trust-owner edits do not enter these hashes. All **17 preimage matches were unique** in the bounded, in-memory check; no shared implementation was written by this author.

| Shared file | Preimage regions SHA-256 | Postimage regions SHA-256 |
|---|---|---|
| `PluginUIModel.swift` | `7b25ecbf6bad1aa25b277b420f8acd332fa26a6355ca26c1b6fd967c889b0fd2` | `7d8e5570554516e940bda839cbf3fe41182364db269a022b9f669e2fdb9e6bb8` |
| `PluginUILifecycle.swift` | `3d38e9385fa56e49dfb0961bef1bedce082f26cf1940d6a46c30f4050b123ddb` | `85baac454f681c6b96cf516d2ccf488a85d0ae34505cb6be7ec3ba230b748d7b` |
| `PluginUIBridgeExtension.swift` | `91f86b151e6842e42f216cbfa20282b2db1230bc9899c8a1ca079e0ae017f1d3` | `8c5a5ed47804a6a6a7b3f5ec7dc12385b60a441d2dfcd4fcdd8738335ad82398` |
| `submodules/TelegramUI/BUILD` | `bd8edd5076d91b522f20e8ec8f2fe6cf0457b91be058bbbc8471723eae7d8df7` | `42b25e790324f1ebda9b6427265270f154049c0ea58e06575bbc5572707de3e2` |

Source syntax/whitespace and diff checks passed. Original SDK inputs and the provided Host-test pin from the review still match. **MCA-F01's native integration awaits this coordinator delta; full native compilation, real-CPython integration and recorded-frame acceptance are not claimed.** The baseline sections above and the independent review retain their original checkpoints.

### Coordinator APPLIED — follow-up delta

All17 postimage hunks are now present across Model/Lifecycle/Bridge/test source
group. The ten owned-file hashes above still match exactly. Native permission
predicates and terminal FIFO/release wiring remain in the joined source.
Independent follow-up of both counterexamples is running; the new seven native
regressions and real recorded frames still require the next Apple gate.
