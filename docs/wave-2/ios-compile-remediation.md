# Full iOS compile: first source blockers

Run `43736634873 / e8484ec0` passed package loading and reached actual iOS
compilation. Its repeated errors have three root causes:

- New annotated MtProtoKit declarations activated nullability-completeness errors
  in neighboring legacy method signatures. Explicit `_Null_unspecified` retains
  their prior imported contract while completing the header annotations.
- `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS. The settings
  durability-root default now uses `URL(fileURLWithPath: NSHomeDirectory(),
  isDirectory: true)`, the actual process home on iOS and desktop platforms.
  The corresponding native-capable path fixture uses that API too.
- The Postbox message-history registration used implicit strong `self` outside a
  nested weak capture. The outer capture is now explicit, preserving the original
  short registration lifetime and weak disposable cleanup.

The next supported full build must typecheck these changes. No compiler warning
policy or native ownership checks were disabled. PostboxImportCheck passed.

Independent Mac component `43737993772 / e2a5684c` hit a cold **20-second compiler**
timeout in the original Foundation UI fixture before it reached SDK execution.
That driver now uses the existing process-tree-bounded launcher with a separate
120-second compile budget and 25-second execution budget. It retains the same
fixture source set and assertions; this is not a longer SDK/plugin runtime limit.

## Follow-up from 43738711102 / 136c946f

The next full compile found unannotated properties/block arguments in the same
two MtProtoKit headers. All remaining pointer sites now explicitly retain
`_Null_unspecified`, including nested callback arguments and return types.

The Emoji cmap-14 reader used CoreText's iOS-unavailable `excludeSynthetic` option.
It now reads the exact installed `CGFont` table through `table(for:)` (available
since iOS 2), preserving raw-font variation support checks and the 1-MiB bound.
Apple API declaration: https://developer.apple.com/documentation/coregraphics/cgfont/table(for:).

## TelegramCore pass from 43740868881 / fac6cf26

The previous header and Emoji blockers passed. TelegramCore then exposed 25
source diagnostics across Account, resolver/privacy captures, TL enqueue and
typed data adapters; their focused correction cohorts have separate receipts.

The new `MTRequest.initWithLogContext:` initializer is explicitly nonnull, matching
its NSObject initialization and always-created log context. Legacy method
nullability remains unspecified. The credential-safe failure mirror now supplies
`KeyValuePairs<String, Any>` to Mirror's labelled-child overload; raw RPC error
contents remain outside the reflection children.

## Downstream pass from 43744733589 / 5a4a6287

TelegramCore compiled after the explicit prepared-Network return types.
Four downstream diagnostics required these local corrections:

- Camera's secondary native-resolution factors already are `[CGFloat]`; append
  them directly. Explicit numeric mapping closures disambiguate lens-stop types.
- The Rust adapter uses the imported `NSNotification.Name` resolver-change name,
  as the native resolver consumers already do.
- Map snapshots import legacy SwiftSignalKit with `@preconcurrency`. Its captured
  `Atomic<UInt64>`, `MetaDisposable` and `Subscriber<Data?, NoError>` use their
  existing pthread locks; emissions are serialized on the subscription queue and
  guarded by generation/cancellation. No own state or warning policy was widened.

## Camera factories from 43747293127 / 99561d4a

The next compiler pass reached Legacy/Neo camera factories. Their zoom promises
now start with a cached optional nil value, using `Promise<T>.init(_ value: T)`.
Passing `.single(nil)` selected the signal-initialization overload without its
required label. A lazy `initializeOnFirstAccess` nil signal would also overwrite
an already-attached live zoom stream at the first subscriber; the value initializer
preserves that stream and retains the intended initial unavailable state.

## Composer pass from 43749522967 / e766b61e

The compiler reached ChatTextInputPanelNode. Placeholder invalidation now reads
the prior `presentationInterfaceState` before it is assigned, rather than a local
`previousState` declared later in a nested scope. The inline-math button uses iOS15
`UIButton.Configuration` content insets, font attributes and title wrapping instead
of deprecated `contentEdgeInsets`; its14-point horizontal insets and Dynamic Type
subheadline remain explicit. The normal native frame-size/tap logic remains in place.
The UIKit frame gate must inspect the actual suggestion control.

## Gallery pass from 43751350772 / 00bf3344

Composer compiled. The dictionary-lookup presentation's `MainActor.assumeIsolated`
result is now explicitly discarded. Its body still calls the captured export
permit and presents only inside the admitted/owned-controller block; discarding
the return does not move presentation outside that guard.

The same deprecated button-inset pattern remained in the new Pill header. It now
uses directional configuration insets (38 leading /16 trailing), the same Dynamic
Type subheadline/truncation, native title/color updates and the existing0.16s
crossfade. Existing `pill-render` expectations cover the affected control; this
source correction does not itself certify its recorded frames.
