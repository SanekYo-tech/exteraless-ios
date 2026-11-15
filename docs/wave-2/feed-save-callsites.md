# FU-02 final Save callsite audit

2026-11-15, source-only snapshot. Paths below are relative to
`telegram-ios/submodules/`. Native execution/Photos/export/frame acceptance remains pending.

Exhaustive source query (including multiline-call starts):

```text
rg -n --glob '*.swift' '\bsaveToCameraRoll\s*\(' telegram-ios
```

Result: **23 matches = 14 actual calls to the SaveToCameraRoll facade + 5 calls to
ShareController's private overloads + 4 declarations**. All seven facade calls in
the assigned inherited Feed/Gallery/Share flow now pass the same permit/reference.

## Inherited-flow facade calls — all applied

| Source | Line | Route / final admission |
| --- | ---: | --- |
| `GalleryUI/Sources/Items/ChatImageGalleryItem.swift` | 785 | Direct photo Save; captured reference + item generation + per-operation success receipt |
| `GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift` | 4063 | HLS quality Save; original selected quality reference, player/item generation, receipt before SaveProgressScreen completion |
| Same file | 4104 | Local video Save; captured original permit/reference, generation and receipt |
| Same file | 4162 | Image/paired Live Photo Save; original image/video references, generation and receipt |
| `ShareController/Sources/ShareController.swift` | 2633 | Message batch; original composite IDs and retained validator reference |
| Same file | 2663 | Image-representation subject; inherited source permit survives standalone media conversion |
| Same file | 2679 | Exact media-reference subject, including the CMC named-medium branch |

The first four pass `exportCurrent` and `exportValidity`. Item replacement, media
replacement, loss of centrality/visibility, exit and player replacement invalidate
the captured generation. The synchronous predicate is checked inside the actual
Photos effect admission even if the validity notification is still queued. Missing
presenters cannot turn a captured nonnil grant into nil. Each Save attempt requires
its own receipt; making receipt state does not renew the generation or grant.

All seven reach `SaveToCameraRoll/Sources/SaveToCameraRoll.swift:374`. A nonnil permit
selects the finite guarded operation; its Photos change block calls the supplied
commit guard before asset creation. Refusal/failure/cancel produces no 1.0 receipt.

## Actual Share factory selection

The full query exposed that `TelegramUI/Sources/SharedAccountContext.swift:4632`
now maps `makeShareScreen` to the component ShareScreen. The granted flow is
therefore explicitly routed through the existing **`makeShareController`**:

- `TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedActions.swift:319`.
- `GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:143–152` selects the
  guarded controller for a nonnil permit and binds that same instance immediately.
  Its five callers are at 571, 1871, 2068, 2159 and 2323.
- `SharedAccountContext.swift:4686–4697` constructs the actual `ShareController`
  containing these terminal guards. That common-root implementation was read only.

The Footer retains CMC exact selection/live-time handling and `prepareShare`
before/after readiness. Its nil-permit branch uses the ordinary screen factory.

## Remaining facade matches — stock, outside this assigned inherited flow

| Source | Line | Existing caller |
| --- | ---: | --- |
| `BrowserUI/Sources/BrowserInstantPageContent.swift` | 1644 | Browser / Instant View |
| `InstantPageUI/Sources/InstantPageControllerNode.swift` | 1433 | Instant View |
| `TelegramUI/Sources/ChatInterfaceStateContextMenus.swift` | 1498 | Native Chat menu |
| `TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageGestures.swift` | 121 | Chat gesture owner |
| `TelegramUI/Components/ShareScreen/Sources/ShareScreen.swift` | 704 | Ordinary component ShareScreen; granted Feed/Footer calls use the explicit factory above |
| `TelegramUI/Components/PeerInfo/PeerInfoStoryGridScreen/Sources/PeerInfoStoryGridScreen.swift` | 268 | Story grid |
| `TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemSetContainerComponent.swift` | 6006 | Story Save |

These stock callers were not edited. No avatar caller appears under this exact
facade name. The scope does not change unrelated story/avatar/media-parser behavior.

## Non-facade matches accounted for

- Five private-overload invocations in `ShareController.swift`: 632, 656, 659,
  665 and 680. They reach the three guarded facade calls above.
- Three private-overload declarations in that file: 2622, 2654, 2671.
- The public facade declaration in `SaveToCameraRoll.swift`: 374.

Frozen implementation bytes: `feed-fu-native-frozen.sha256`. CMC09 live-Double /
player-accessor slice SHA-256 (UTF-8 LF text):
`3ba75f5b86dce2e0d1828999afb5d7b046e10e84e8d5a68b3db83d2148f2e298`.
Read-only CMC request/selection file SHA-256:
`265bd54de62cf33f5e8633323077520ad27b27209ee2608e6a89a089aaac9d6b`.
