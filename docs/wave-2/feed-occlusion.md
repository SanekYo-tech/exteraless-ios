# FPP-03 — stable content-occlusion contract (Feed / native Mini Player)

Owner: Feed remediation. Publisher wiring: Player author / coordinator.
Implementation target: `telegram-ios/submodules/AccountContext/Sources/ExteralessContentOcclusions.swift`.
All API calls and callbacks are **main-actor isolated**. No TelegramCore/UIKit dependency is introduced.

```swift
@MainActor
public final class ExteralessContentOcclusions {
    public static let shared: ExteralessContentOcclusions

    public struct Snapshot: Equatable {
        public let accountId: Int64
        public let revision: UInt64
        public let rects: [CGRect]
    }

    public func publish(owner: UUID, accountId: Int64, window: UIWindow, rects: [CGRect])
    public func clear(owner: UUID)
    @discardableResult
    public func subscribe(accountId: Int64, window: UIWindow,
                          updated: @escaping @MainActor (Snapshot) -> Void) -> UUID
    public func unsubscribe(_ subscription: UUID)
}
```

## Publisher rules — ready for Player implementation

- Retain one UUID per native overlay publisher. Pass the **owning**
  `context.account.id.int64`, never a subsequently selected global account.
- Rectangles are the currently drawn opaque/interactive overlay regions in the
  **actual UIWindow's coordinate space**, e.g.
  `miniView.convert(miniView.bounds, to: window)`. Feed converts them into its own
  table coordinates. Publish actual 64/52pt/top/bottom/compact geometry; do not pass
  a guessed bar height or the frame in root-controller coordinates.
- Publish after attachment/layout, after top/bottom/compact/keyboard/Duo changes,
  and during animated geometry changes if the overlay remains on screen. Use
  presentation-layer geometry or the union of old/new rectangles while an animation
  is unsettled. In steady state publish only the current rectangle.
- `clear(owner:)` removes **only this owner** on hide, detachment, account retirement
  and disposal. It does not clear another overlay's rectangles. A later intentional
  reappearance may reuse the owner; the publisher must reject its own stale callbacks.
- Publishing an existing owner atomically replaces its previous account/window/rects.
  Empty rects are equivalent to clear. The registry weakly retains windows, clips to
  window bounds and delivers only matching account + identical window snapshots.
- `subscribe` immediately delivers the current snapshot, including an empty one;
  retain the returned UUID and unsubscribe on disappearance/window replacement.
  Identical publications do not cause another callback. Callbacks can reenter the
  registry; consumers receive revisions in order and stale snapshots are discarded.

```swift
// Inside the Mini Player's existing account/visibility lease, on main:
if let window = miniView.window, miniIsActuallyVisible {
    ExteralessContentOcclusions.shared.publish(
        owner: occlusionOwner,
        accountId: context.account.id.int64,
        window: window,
        rects: [miniView.convert(miniView.bounds, to: window)]
    )
} else {
    ExteralessContentOcclusions.shared.clear(owner: occlusionOwner)
}
// Retirement/hide: clear(owner: occlusionOwner), even if miniView.window is now nil.
```

## Feed consumer

Feed retains native keyboard/tab/navigation/Duo insets, then adds space for occlusions
adjoining its top/bottom content edges. It also subtracts the current overlay rects
for visibility/metadata and explicitly rejects a receipt for a bubble/album that still
intersects an occlusion, including the tall-post path. Merely reducing the viewport
height must not turn an obscured tall post into an admitted receipt.

The registry is geometry only: it does not read messages, send receipts, mutate player
state, or guess privacy policy. Model tests use tiny rectangles; native registry tests
use synthetic UIWindows without Account/Network. Recorded phone/Duo/top/bottom/compact
frames remain a separate native verification requirement.

## Implementation handoff

Feed consumer is wired in `Feed/ExteralessFeedScreen.swift`; the current Player-author
`ExteralessPlayerOcclusionPublisher.swift` calls this exact `publish` / `clear` API and
`ExteralessPlayerIntegration.swift` instantiates it. Native build/frames are still pending.
Account-free debug window prototype: `ExteralessFeedOcclusionPrototype` in Feed sources.
Full remediation/test/FROZEN-slice record: [`../feed-remediation.md`](../feed-remediation.md).
