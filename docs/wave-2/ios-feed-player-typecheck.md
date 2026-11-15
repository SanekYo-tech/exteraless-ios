# iOS Feed / Player / Pill — TelegramUI compiler handoff

2026-11-16. **Source corrections applied; native compilation, XCTest and recorded
frames remain pending.** Scope: 16 compiler errors at 11 source sites in the nine
assigned Swift files, from main TelegramUI pass `43761767575` / `f05473ea76`.

- Input log: `C:\Users\sasha\AppData\Local\Temp\opencode\ipa-f05473ea-failed.log`.
- Log SHA-256: `44bbe728503d02f3103b75119344ad0ad4a710722195c63e88e752c6532ee749`.
- Working-tree HEAD at baseline capture: `4bcf80a0d7160264accbb6b415facde82cf87928`.
- `telegram-ios/CLAUDE.md` and `telegram-ios/AGENTS.md` were read before editing.

## Diagnostic mapping

Paths below are relative to `telegram-ios/submodules/TelegramUI/Sources/`.
Line numbers identify the original diagnostics.

| Source / line | Actual declaration or diagnostic | Applied correction |
| --- | --- | --- |
| `ExteralessClient/Feed/ExteralessFeedMessageCell.swift:54` | Inherited UIKit selection is `Bool`; the owned renderer cache is `Bool?`. | Rename the private cache and both references to `renderedSelection`. Preserve the `configure(... selected: Bool?, ...)` argument and its three states. |
| `ExteralessClient/Feed/ExteralessFeedMessageInteraction.swift:150` | `ChatPresentationInterfaceState/Sources/ChatMediaInputNodeInteraction.swift:5–10` declares public `ChatInterfaceStickerSettings` and its empty initializer. | Import `ChatPresentationInterfaceState`; use the existing typed initializer. |
| `ExteralessClient/Pills/ExteralessPillRuntime.swift:83,127` | Bare `catch` binds an immutable `Error` named `error`, shadowing the intended string. | Rename both owned string locals and all six uses to `errorMessage`. Preserve captured leases, cancellation branches, migration/Ghost helpers and worker/main-queue boundaries. |
| `ExteralessClient/Player/ExteralessMiniPlayerView.swift:19` | SDK `UIResponder.h:84` declares inherited `nextResponder`, imported as `next`. | Rename the owned button and every reference to `nextButton`. |
| `ExteralessClient/Player/ExteralessPlayerSurface.swift:43` | Same inherited responder property. | Rename this surface's owned button and every reference to `nextButton`. Playback `.next` actions and selectors retain their original meaning. |
| Same file, `:441` | The log includes the actual `UIView.h:409` declaration: `- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer`. | Add `override` to the existing Swift method; preserve its swipe predicate/body. |
| `ExteralessClient/Player/ExteralessPlayerOcclusionPublisher.swift:30` | `AccountContext/Sources/ExteralessContentOcclusions.swift:6–8` isolates the class and `shared` to `MainActor`. Default arguments are checked outside the initializer body. | Default `registry` to optional `nil`; resolve `registry ?? .shared` inside the existing actor-isolated initializer. |
| `ExteralessClient/Player/ExteralessPlayerVisualSurface.swift:67` | `ExteralessMiniPlayerVisualSurface` is already `@MainActor`; its default registry expression had the same error. | Accept optional `nil`, resolve the registry locally inside that initializer, then construct the mini view/publisher there. Explicit injected registries retain identity. |
| `ExteralessClient/Player/ExteralessPlayerSession.swift:424` | `TelegramCore/Sources/TelegramEngine/Resources/TelegramEngineResources.swift:149–162` declares `ResourceData` as a class with `path`, `availableSize`, `isComplete`. | Filter the existing data signal on `$0.isComplete`, matching the earlier EmojiPack adapter. |
| `OverlayAudioPlayerControllerNode.swift:1213` | The call is inside ordinary `invalidateExteralessPlayerAccount()` at `:1209`; `ExteralessPlayerSession.invalidate()` is main-actor isolated. | Mark the owned invalidation entry point `@MainActor`; its synchronous body stays intact. |

### Resource facade and lifecycle evidence

`TelegramEngineResources.swift:493–510` returns
`Signal<EngineMediaResource.ResourceData, NoError>`. Its `:209–212` conversion maps
native `path`, `size`, `complete` directly to `path`, `availableSize`, `isComplete`.
The `.complete(...)` at `:502` belongs to the request option; `Fetching` belongs to
the separate `FetchStatus` enum at `:165–170`. The session keeps the emitted file
path, first-complete admission, loaded-key checks, cancellation, three-second asset
timeout, and playback identity/asset-currentness guards.

The Overlay call chain was inspected before adding isolation:

- `OverlayAudioPlayerController.swift:63–75`: active-account observation delivered
  on the main queue, created in the UIKit controller initializer.
- Same file, `:285–292`: UIKit `viewWillAppear` account rejection.
- `Display/Source/ViewController.swift:86`: the controller base inherits
  `UIViewController`. These are the only two call sites.
- The actual Overlay node `deinit` at `:624–631` performs observation/disposable
  cleanup. The reported session call belongs to account invalidation.

The annotated entry point sets the account-invalid flag, cancels pending profile
work, invalidates the session and disables interactions in the same main-actor
turn. Session `invalidate()` retains its existing idempotent account guard and
`stop()` cancellation. Publisher retirement stays actor-isolated; its existing
destruction backstop captures only its owned owner UUID and registry.

## Finite source checks and BUILD handoff

- Strict UTF-8/NUL checks and exact comparison with the nine captured baselines
  passed. Reversing only the listed lexical/API edits recovers every original
  source byte: renderer/state/IDs, button layout/actions, worker/provider code,
  metadata cancellation/generation and destruction bodies are preserved.
- Actual module/type/resource declarations, SDK override note and both Overlay
  callers were checked as described above.
- `TelegramUI/BUILD:178–183` includes all nine files through `Sources/**/*.swift`.
  The production target already has the direct import edge
  `//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState`
  at `:409`. There is no missing BUILD edge for this added import.
- `ExteralessFeedTestsLib` (`:734–750`) and `ExteralessPlayerNativeTestsLib`
  (`:795–804`) compile their test sources and depend on `:TelegramUI`.
- Scoped `git diff --check` passed. The exact delta passed both forward
  `git apply --check --whitespace=error` against the captured `before/` tree and
  reverse `git apply --reverse --check --whitespace=error` against the working
  tree, with `core.autocrlf=false`. These commands checked applicability only.

Verification here is bounded local source/header/patch inspection. Native Swift
typechecking and frame acceptance were not performed on this Windows host. No
CI, commit, network, live-account, AudioDevice or I/O-plugin execution occurred.
The delta contains only the nine assigned Swift paths; the Search owner's
`ExteralessPlayerActions.swift` work and FontVariantSymbol/focus code are outside it.

## Exact source SHA-256

Raw working-tree bytes, including newline encoding. Prefix:
`telegram-ios/submodules/TelegramUI/Sources/`.

| Source | Before | After |
| --- | --- | --- |
| `ExteralessClient/Feed/ExteralessFeedMessageCell.swift` | `0aaa6dd93e0867ff1baea1dfb9d87c00da895071c6e97295ab9b38938678f12a` | `f7a3d6cbb953c6be40e0886b334606c890267ce45e476bf14b4b7d67159fdbdb` |
| `ExteralessClient/Feed/ExteralessFeedMessageInteraction.swift` | `9ccc1f9885df9a83133c465f3cfe1be0390a975f69dd7697318165e5af227f4b` | `644c530d1fc0b34a1027ab8cfda2ec0a2a51947c4986ba5bfc628bb0fd5306b9` |
| `ExteralessClient/Pills/ExteralessPillRuntime.swift` | `f7f177994ebc0356cd7ddb2163b26b8522b10f64bd00debfb260b8fa747d8faa` | `16437f700cdac99674a48c7ffd5dcf310b825f58dd85a19f2a482702519a5f64` |
| `ExteralessClient/Player/ExteralessMiniPlayerView.swift` | `71bfc2b70b0dc707a904c8f1413deca70ad9ab40ce18bcfb3b98ce1c869a8215` | `e4f49287f6a5dbed82e3b976f2ac61b6b12a006c76136f038afda2a5fc0f0d07` |
| `ExteralessClient/Player/ExteralessPlayerOcclusionPublisher.swift` | `b1942f17b11c07a1406cd392a6e3494b7e5c4c016e615ce6ce5c327277e02bf0` | `533a16df9b3c9611dafcea5aa652bf548a8b6ed4b6062e5e3b80248ca96113f6` |
| `ExteralessClient/Player/ExteralessPlayerSession.swift` | `d69de84f1b47cccd73599f8bc6b6e8d852a5409b7511f92b53b70fbdf83f9087` | `985c5ee39250be83138aa6a992e781a26bbae4a5cca4e053da0fe759bba48666` |
| `ExteralessClient/Player/ExteralessPlayerSurface.swift` | `bcdf9e61c3c84ec274d0967f166cbb5bfba7e3edd55c6bbfa1015172f1f2c708` | `4cbfd3f099d99362775a0d3ce3db7a4fe3a50af4b66f0a7f8ce25a55cc611284` |
| `ExteralessClient/Player/ExteralessPlayerVisualSurface.swift` | `0b2fd78e3279d3f54e80ba1d89c36fc7d5f099a617a0aefa19da8f8fc4b70109` | `18689061c0965bdd3bd7df1ca32c80ae0bfb91b8edf4d9b91b69d74a8cffe623` |
| `OverlayAudioPlayerControllerNode.swift` | `e23289f5a4bbe4db7c4c4e8dffcb6d43d693e0b8fe1a363c7f1942851bf3512a` | `988e98ea3215a3bf929270f88383dde054cae90cce599c449e3c8b3bc3787287` |

## Exact delta SHA-256

- Bytes: **19973**.
- SHA-256: `a537bf7fda1f05dd201ad6303e9ae244b461361209c8aa2dba0174e2d039de02`.
- Artifact: `C:\Users\sasha\AppData\Local\Temp\opencode\ios-feed-player-typecheck-04b277e7be2c44b4b43b1a0718fe8978\ios-feed-player-typecheck.patch`.
- That directory also contains raw `before/` and `after/` snapshots and
  `source-hashes.json`.

Format: UTF-8 without BOM, Git binary-capable unified diff with full index hashes
and repository-relative `a/` / `b/` paths. Generated with
`git -c core.autocrlf=false diff --no-index --binary --full-index --no-ext-diff
--no-textconv --src-prefix=a/ --dst-prefix=b/ before after`, then removing the
snapshot-directory components from path headers. The delta covers Swift sources;
this handoff document is additional.

## Coordinator gate

1. Reconcile the captured before/after hashes with the integration snapshot.
2. Run the integrated native compiler gate and existing Feed/Player native tests:
   `//submodules/TelegramUI:ExteralessFeedTests` and
   `//submodules/TelegramUI:ExteralessPlayerNativeTests`.
3. Complete the existing recorded-frame acceptance for retained Feed state and
   mini/full-player layout, gestures and account/window occlusion lifetime under
   `AGENTS.md`. Evidence stays **partial** until those native gates pass.
