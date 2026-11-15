# Final explicit visual batch — Avatar / Composer

Source implementation is in the same `ClientUIHarnessLib` / loginless app as the
existing two cohorts. Native compilation and recorded-frame review are pending.
The coordinator owns the small factory patch and Build owns the edges below.

## One required production join

Apply **`composer-native-factory.patch`** from the outer checkout root. Its single
new DEBUG source is
`submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessComposerVisualFactory.swift`.
The 24-line wrapper invokes the actual
`inputPanelForChatPresentationIntefaceState` and loads its selected input node.
It returns `ChatTextInputPanelNode?` for a supplementary `composer-harness-*`
Account and supplies no rendering, parser, image provider or editing algorithm.
The normal producer installs **MediaItemNodeView** and
**chatInputContentFromPastedMarkdown** itself. Harness code invokes public native
selection/Date/Mention/paste/undo capabilities. The wrapper's source is mandatory
in the manifest when selecting `composer-render`.

No Avatar patch is needed. The AF-01…04 public cache/complete-image/overrideLetters
APIs are used directly. ASC01 uses the coordinator's `ImageNode.Crossfade` layer
and `clearContents()` fix, not another implementation. The already-joined Avatar
XCTest target/mapping remains separate from this app's recording scenario.

## Required direct imports on ClientUIHarnessLib

Add these to `//Tests/ExteralessHarness:ClientUIHarnessLib.deps`:

```starlark
"//submodules/AvatarNode:AvatarNode",
"//submodules/DirectMediaImageCache:DirectMediaImageCache",
"//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
"//submodules/TelegramUI/Components/Chat/ChatInputTextNode:ChatInputTextNode",
"//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer:ChatRichTextEditorComposer",
"//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode:ChatTextInputPanelNode",
"//submodules/TelegramUI/Components/RichTextEditor:RichTextEngineEditor",
"//submodules/TelegramUI/Components/RichTextEditorMediaView:RichTextEditorMediaView",
```

All new harness Swift files are selected by the existing `Sources/*.swift` glob.
The context adds only the panel's stock limits/chat defaults, explicitly empty
offline emoji inventory and ordinary non-premium fixture identity, real config
freeze policy, and the actual InputDec experimental flags. Each new context
endpoint requires `composerRendering`; other services stay named traps. DCT's two
already-joined dependencies serve Composer too. CryptoKit is an iOS system module.
No new generated interaction source or blanket fake framework is required.

The DEBUG factory lives in the existing TelegramUI source glob and uses its
existing direct AccountContext/ChatPresentationInterfaceState/ChatTextInputPanelNode
edges. Preserve DEBUG for TelegramUI. `composer-render` checks iOS >=18.4 and the
**constructed** `RichTextEngineEditorView`; failure is not a legacy fallback.
The app keeps the top-level production framework/resource graph, including
`:RichTextEditorUIKitResources` through its normal library edge. No second
ComposerHarness app, fake test host or duplicate canvas is installed.

## Extend the existing build-time source resource

Keep `DomainSourceManifest` / `client-ui-domain-sources.json`. Add a filegroup named
`ClientHarnessFinalVisualFingerprintSources` in each package below, with visibility
`["//Tests/ExteralessHarness:__pkg__"]`. Paths are relative to that package.

| Package | `srcs` |
|---|---|
| `//submodules/AvatarNode` | `glob(["Sources/**/*.swift"])` |
| `//submodules/DirectMediaImageCache` | `glob(["Sources/**/*.swift"])` |
| `//submodules/Display` | `Source/ImageNode.swift`, `Source/DisplayLinkDispatcher.swift`, `Source/TransformImageNode.swift` |
| `//submodules/TelegramUI` | `Sources/ExteralessClient/Chats/ExteralessComposerVisualFactory.swift`, `Sources/ChatInterfaceStateInputPanels.swift`, `Sources/PastedMarkdownConversion.swift`, `Sources/Chat/ChatControllerLoadDisplayNode.swift` |
| `//submodules/TelegramCore` | `glob(["Sources/ChatInputContent/**/*.swift"])`, `Sources/SyncCore/SyncCore_CloudFileMediaResource.swift`, `Sources/SyncCore/SyncCore_AppConfiguration.swift`, `Sources/TelegramEngine/Resources/TelegramEngineResources.swift` |
| `//submodules/ChatPresentationInterfaceState` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TelegramUI/Components/Chat/ChatInputTextNode` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TelegramUI/Components/RichTextEditorMessageConversion` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TelegramUI/Components/RichTextEditorMediaView` | `glob(["Sources/**/*.swift"])` |
| `//submodules/TextFormat` | `Sources/ExteralessComposerMarkdown.swift`, `Sources/DateFormat.swift` |
| `//submodules/TelegramUI/Components/RichTextEditor` | Native model/editor/engine input dirs specified below |

For the last row, include actual native source inputs (not Host test fixtures):

```starlark
glob([
    "Sources/%s/**/*.%s" % (directory, extension)
    for directory in [
        "RichTextEditorCore", "RichTextEditorUIKit", "RichTextEngineEditor",
        "RichTextInputDecHost", "RichTextInputDecObjC", "RichTextInputDecUpstream",
    ]
    for extension in ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp"]
])
```

Add each of those **13** package labels, suffixed
`:ClientHarnessFinalVisualFingerprintSources`, to the existing
`DomainFingerprintInputs.srcs`. The existing Account/Retention/PhotoResources and
harness globs already cover `RetentionReadiness.swift`, `ClientHarnessReadiness.swift`
and the new native input/artifact/scenario files. Do not add a second copy of the
same input: the generator rejects duplicate canonical paths.

In `swift/ExteralessCore/BUILD.bazel`, extend the existing
`ClientHarnessDomainFingerprintSources` with
`Sources/ExteralessCore/AppearancePolicy.swift` and
`Sources/ExteralessCore/AppearanceFeatures.swift`. The staged `@exteraless` copy
inherits that BUILD as before. This captures the actual shape policy/defaults.

The driver checks exact additional Avatar/Composer source paths before simulator
creation, then compares the running app's complete manifest with this same IPA.
`client_ui_harness_visuals.py` is a new sibling of the two existing driver modules;
include it in the driver's source checkout. No new runtime media resource entry:
the two owned 74-byte PNGs are literal inputs in `ClientHarnessLocalImages.swift`.

## PFR typed-readiness join (implemented entirely in harness)

`clientHarnessAccountWithReadiness()` subscribes to the public
`ExteralessAccountRecoveryCenter.shared.pending` **before `HarnessAccount.make()`**.
It reads each still-owned handle's current typed status. A failed native owner
disposes its recovery/account subscriptions and delivers the same
`ExteralessRetentionReadinessFailure` to the app report. The only success value
comes from the real Account factory after its readiness/token/transfer barriers.
This closes the old NoError wrapper's hidden `.retentionRecovery` outcome without
editing its constructor. There is one factory in this fresh process, and no
retry/reset button or fabricated ready result. The preparation/public configure
API, private API vault, full retention snapshot and proxy-before-open ordering
are the contract in `bootstrap-compatibility.md`.

## Three explicit serial invocations, same newly built IPA

Keep the existing baseline summary **exactly 3** and domain summary **exactly 3**.
Add a separate final-visual summary **exactly 2**, after those invocations, under
the existing owned workspace lock. The driver accepts subsets only when explicitly
selected, never a mixed-cohort or >3-process invocation.

```sh
python3 tools/runtime/client_ui_harness.py \
  --ipa "$IPA" --staging-manifest "$MANIFEST" --telegram-root "$TELEGRAM_ROOT" \
  --output "$ARTIFACTS/final-visuals" \
  --scenario avatar-render --scenario composer-render
```

`acceptance.json` now declares `requestedScenarios`, `batch` (`baseline-3`,
`domains-3`, `final-visuals-2`), `processLimit: 3` and `buildSelection` with
`//Telegram:ClientUIHarness` / `org.exteraless.ClientUIHarness`. Success requires
**exact ordered semantic results AND recordings** for that declared selection.
Do not turn the first-six guard into an eight-case default or count a partial
recording as an executed scenario. One fresh simulator per invocation; fresh app
processes sequentially; native alarm and external deadline both remain 30s.

Upload `final-visuals/**` with the existing artifacts. Each added case also retains
`native/*.png` (only declared/hash-checked view captures), `frame-handles.json`
(ffprobe PTS/index + PNG/sheet + semantic/event links), and the existing MP4,
`ffprobe.json`, `frames.tsv`, sheets, state, trace, timing and source manifest.
ASC01 must be reviewed at its `active-frame-1/2` → `reset-to-letters` brackets;
neither the model opacity nor a final screenshot constitutes that review.

Expected frames/timing are specified in `docs/wave-2/ui-harness.md` **before any
recording**. The coordinator performs native execution and frame review after the
joined cohort. No CI/build/workflow/helper edit or dispatch was made by this role.
