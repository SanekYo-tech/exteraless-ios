# UIKit Manager/Reset typecheck — 43797987677 / 84a0456a

The Map fixture compiled. The full debug simulator build then reported three
diagnostics in the main TelegramUI module:

- `PluginUIManagerCustomCell` inherits `UIGestureRecognizerDelegate` from
  UITableViewCell in the pinned SDK. The redundant conformance is removed and
  the existing gesture method explicitly overrides its inherited declaration.
  Root/inline long-press selection logic is retained.
- The reset gate's generic class constraint does not accept `any AccountContext`
  as its generic type. The caller now passes the underlying objects as AnyObject;
  Optional.map preserves an absent current context as nil. The same captured
  context constructs the page after the gate's object-identity/authority checks.

Diagnostics: `build/artifacts/client-ui-43797987677/build/build.log`.
The next full app/Harness pass must verify these changes and reach native/frame
acceptance. Runtime33 remains independently passed in its component scope.
