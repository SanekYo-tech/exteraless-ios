# Native glass actor follow-up

Captured run: `43834798503`, revision
`b06bb00064157eb2df3d21a3cf0166e8e33cd259` (after `bfcce7bc`),
Xcode 27.1 / iPhoneSimulator 27.1.
Input log: `build/artifacts/client-ui-43834798503/native-tests/compile/console.log`.
Fixture: `telegram-ios/submodules/TelegramUI/Components/NavigationExpansionTransition/Tests/GlassShapeKeyframesTests.swift`.

## Actual notes and types

- Log lines 494-496 identify the imported overload as
  `@MainActor animateShape(sizes: [CGSize], cornerRadii: [GlassBackgroundView.CornerRadii], ...)`.
- Lines 523-534 report sending `radii` from the nonisolated test and a potentially
  concurrent local access in the following loop. That loop checks `radii.count`
  against the actual layer animation values. Lines 359-521 also recommend
  `@MainActor` for both initial geometry tests' UIKit calls.
- `GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift:308-319`
  declares `GlassBackgroundView.CornerRadii` as an `Equatable` struct with four
  immutable `CGFloat` fields and no declared `Sendable` conformance. The decoded
  assertion values use the separate `Display.CornerRadii` struct from
  `Display/Source/CALayerCornerRadii.swift:6-17,86-99`.
- The captured compile log contains no `fillPath` text; this fixture contains no
  local `make` function or `fillPath` capture. The real production path builder
  at `GlassBackgroundComponent.swift:394-433` creates a `CGMutablePath` and captures
  it in synchronous `addCorner` calls. The production `animateShape` overload at
  line 2161 feeds actual Core Animation values and generated `CGPath` instances.

## Correction

Added `@MainActor` to the two initially nonisolated test methods and the recursive
`layers(_:)` helper. The other two test methods already carry that annotation.
The radius arrays are now created, supplied to `animateShape`, and inspected on
the main actor. Layer traversal and the synchronous map/filter closures share
that actor; the existing path assertions still inspect production CoreGraphics
output. The change consists of exactly three annotation lines.

## Bounded source verification

- Existing `tools/runtime/native_test_plan.py::fixture_classes`: **1 class / 4
  method IDs**, identical to the captured revision.
- Full-source comparison allowing only the three annotation insertions matches
  the baseline. All **25 assertion calls**, geometry, timing, snapshot/value
  inspections, capability checks, and previous transition fixes are preserved.
- Source checks completed in **0.110 s**, with a 30-second command timeout;
  scoped `git diff --check` exited 0. The inspected production source matches
  the captured revision.
- Native typechecking/XCTest execution is pending the coordinator's run after
  cache repair; no native result was produced on this Windows host.

Method IDs:

- `GlassShapeKeyframesTests/test_animateShape_keyframesTheGivenRadii`
- `GlassShapeKeyframesTests/test_animateShape_fourRadii_keyframesTheLayersCornerRadii`
- `GlassShapeKeyframesTests/testAppearanceTintOutlineAndFallbackMasksShareEveryShapeSample`
- `GlassShapeKeyframesTests/testAsymmetricPathsOrdinaryTransitionsAndCancelRestoreAllAppearanceLayers`

## SHA-256

Fixture hashes cover UTF-8 LF source bytes.

| Input/output | SHA-256 |
| --- | --- |
| Captured compile log | `b18b2238738c364bcf5669fcf106b4d30ee7afefc1dda67409f3d27c7d9f6ac4` |
| Fixture before | `1fe71b8a41432d0eb0aef2eb26048891a8811f9c5034bce0b2d18fbde0e902a5` |
| Fixture after | `cf6a1e64f18c6e835e77cc035e7b56a6b324ebb73f58e26f0b2b6960658d2b85` |
| Read-only `GlassBackgroundComponent.swift` | `55007b987996a55976b1f85fd00c74b555fc8ed2474c5e0b3e98b28408add1c0` |
