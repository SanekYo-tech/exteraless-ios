# Native graphics fixture typecheck corrections

Evidence: client-ui run `43812503558`, revision
`93dcb653d408e45fe1327ee2ee945952520548b4`, Xcode 27.1 / iPhoneSimulator 27.1.
Compiler log: `build/artifacts/client-ui-43812503558/native-tests/compile/console.log`.
Log SHA-256: `1f2acdd3a353164aa4f540366bb9b754f6aac358baa7c7d7dd5f169a816d2a49`.

## Corrections and type evidence

Source paths below are relative to `telegram-ios/submodules/`.

| Fixture | Source lines | Compiler log lines | Correction |
| --- | --- | --- | --- |
| `TelegramUI/Components/DCTMultiAnimationRendererImpl/Tests/ToolsDCTRendererTimingTests.swift` | 17, 18 | 976-1005 | Use `CGImage.typeID` in both the type assertion and guard. |
| `TelegramUI/Components/SubcodecMultiAnimationRendererImpl/Tests/ToolsSubcodecRendererTimingTests.swift` | 17, 18 | 933-962 | Use `CGImage.typeID` in both the type assertion and guard. |
| `TelegramUI/Components/NavigationExpansionTransition/Tests/GlassShapeKeyframesTests.swift` | 138, 144 | 1183-1209 | Construct each transition with `.init(animation: .none)`. |
| `TelegramUI/Components/SwitchComponent/Tests/AppearanceSwitchTests.swift` | 19 | 1526-1538 | Construct the transition with `.init(animation: .none)`. |
| `AvatarNode/Tests/AppearanceAvatarRenderingTests.swift` | 71, 85, 106, 125 | 1551-1604 | Construct each transition with `.init(animation: .none)`. |

The SDK diagnostic explicitly replaces `CGImageGetTypeID()` with `CGImage.typeID`.
Both renderer targets still inspect and draw the actual delivered `CGImage`.
The DCT fixture uses `ItemAnimationContext` and the real cache writer/accessor;
the Subcodec fixture uses `SurfaceGroup`, `SCMuxSurface`, VideoToolbox decoding,
and its independent OpenH264 pixel reference.

All seven transition arguments resolve to `ComponentFlow.ComponentTransition`:

- `GlassBackgroundView.update(size:cornerRadius:isDark:tintColor:isInteractive:isVisible:transition:)`:
  `TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift:718`.
- `ComponentView.update(transition:component:environment:forceUpdate:containerSize:)`:
  `ComponentFlow/Source/Host/ComponentHostView.swift:153`.
- `AvatarNode.setStoryStats(storyStats:presentationParams:transition:)`:
  `AvatarNode/Sources/AvatarNode.swift:1483`.

`ComponentFlow/Source/Base/Transition.swift:144-228` defines a struct, its
`Animation.none` enum case, and the public initializer. Its `static var immediate`
at line 216 is initialized to `ComponentTransition(animation: .none)`. Constructing
that value per call preserves the preset's animation and empty `_userData` while
removing the shared mutable property read. These failing test methods already
have `@MainActor`; that annotation does not isolate an imported mutable static.

`Display/Source/ContainedViewLayoutTransition.swift:182-184` separately defines
`ContainedViewLayoutTransition.immediate` as an enum case. The consumer signatures
above establish the struct initializer as the correct replacement here.

## Verification

- Scoped `git diff --check`: exit 0.
- Reused `tools/runtime/native_test_plan.py::fixture_classes` against the baseline
  and edited sources: all 21 XCTest method IDs match (DCT 5, Subcodec 4, glass 4,
  switch 1, avatar 7).
- Full-source comparison to the baseline permits exactly the 11 substitutions
  listed above. All fixture data, native parameters, assertions, method bodies,
  and execution allowances otherwise match. Source verification took 0.248 s
  under a 30-second command timeout.
- Native Apple SDK typechecking, XCTest execution, and simulator frame evaluation
  were not run on this Windows host. Native validation remains pending.

## Source SHA-256

Hashes cover UTF-8 LF source bytes; the edited working files also use LF.
Baseline is revision `93dcb653d408e45fe1327ee2ee945952520548b4`.

| Fixture (paths above) | Baseline | Edited |
| --- | --- | --- |
| `ToolsDCTRendererTimingTests.swift` | `58f8f34444ad529676490698237c653f3961a1cea3c0f2b3f6ebc676d7b39175` | `ce64c27bd4677f6ec520cde1bc1cc0d658820c0e154139f72a28fd231b6fa617` |
| `ToolsSubcodecRendererTimingTests.swift` | `2f51c9dae756c16e641d5939702b938f84f351a3a74dbb97678df39a94ef8687` | `4f0da09e2ea3bcce3243dc314a30725990b7ef671db7dc6ad5c532bbace7ba4c` |
| `GlassShapeKeyframesTests.swift` | `0cc3377eb4a7fc2a7c1c97de993d0416a8357093b84e6147fc94fad086b56c56` | `1fe71b8a41432d0eb0aef2eb26048891a8811f9c5034bce0b2d18fbde0e902a5` |
| `AppearanceSwitchTests.swift` | `1fd6f325c7f31192bf674541d1928f234ce92d11b99cc7b88b7e495c8ed56076` | `471b4f0f55176c42dc27c02aed7e4cbbd06a7672338d8a151a965eb6272c1598` |
| `AppearanceAvatarRenderingTests.swift` | `321916d341d71675f9767eb85862f5f4e862597e7139f1acf78a0d14869df15c` | `310c03b72da1fa586e437eea83bb8c123e10f1f81a981d97babdeebc090acd76` |
