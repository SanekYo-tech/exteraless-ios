# ASC-01 — retire active image crossfades on semantic reset

The coordinator fixed `Display/Source/ImageNode.swift`: its own crossfade layers
now have a private concrete type. `clearContents()` cancels their animations,
releases their bitmap and removes them. Foreign overlays retain their ownership.
Completion closures still act on their original layer only.

`AvatarImageTransitionResetTests.swift` creates a real AvatarNode/ImageNode and
delivers two local images after subscription, requiring an already-active bitmap
crossfade before calling `setCustomLetters`. It checks layer/bitmap/animation
retirement, a retained foreign overlay, and a delayed old completion after the
next transition. This covers the order missing from the earlier queued-delivery
fixtures. The existing Avatar test target includes the new file and Display edge.

The fixture has no network, account, timed wait or Photos effect. Apple XCTest and
recorded frames remain pending. The `avatar-render` harness must record the same
active-fade-to-reset transition; a model-layer screenshot with opacity zero does
not alone prove that the old presentation bitmap disappeared.
