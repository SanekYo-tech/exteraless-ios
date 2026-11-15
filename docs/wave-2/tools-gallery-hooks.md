# Normal Telegram Gallery subtitles — ready adapter + exact chat/player hooks

**A–E and native PiP lifecycle wiring are now applied in source.** See
`tools-gallery-integration.md` for the installed API, callsites, checks and pending
native frames. The snippets below are the original insertion plan, retained for
comparison; the applied bridge additionally has revocable context tokens and passes
the native layout transition. Do not reapply the historical snippets.

Tools provides working source (not just a DTO):

- `TelegramUI/Sources/ExteralessClient/Tools/ExteralessGallerySubtitleAdapter.swift`:
  native picker, bounded security-scoped import, persisted per-account/document
  sidecar, UILabel overlay, clear/dispose, generation guards and timed cue updates.
- `ExteralessCore/ToolsSubtitleStore.swift`: actor-owned sidecars and
  `ToolsSubtitlePlaybackSample`, projected from the **real MediaPlayerStatus** clock.
- `ToolsSubtitles.swift`: SRT/WebVTT parsing, overlapping cues, seek-correct lookup.

No second AVPlayer is created for this integration. These are shared GalleryUI
insertion hunks for the chat/player owner; Tools does not edit that owner's file.

## Small cross-module bridge (chat/player owner adds in GalleryUI/Sources)

```swift
import ExteralessCore
import UIKit

@MainActor public final class ExteralessGallerySubtitleControls {
    public let update: (ToolsSubtitlePlaybackSample?) -> Void
    public let visible: (Bool) -> Void
    public let layout: (CGRect, CGFloat) -> Void
    public let select: (UIViewController) -> Void
    public let clear: (UIViewController) -> Void
    public let dispose: () -> Void
    public init(update: @escaping (ToolsSubtitlePlaybackSample?) -> Void,
                visible: @escaping (Bool) -> Void, layout: @escaping (CGRect, CGFloat) -> Void,
                select: @escaping (UIViewController) -> Void, clear: @escaping (UIViewController) -> Void,
                dispose: @escaping () -> Void) {
        self.update = update; self.visible = visible; self.layout = layout
        self.select = select; self.clear = clear; self.dispose = dispose
    }
}

@MainActor public enum ExteralessGallerySubtitleBridge {
    public static var make: ((String, UIView) -> ExteralessGallerySubtitleControls)?
}
```

GalleryUI already has the Core dependency from chat wave 2. Its normal source glob
includes this bridge. TelegramUI already depends on GalleryUI, avoiding a cycle.

## Composition registration (Tools integration/coordinator after bridge lands)

On main in `ExteralessToolsIntegration.update(context:)`, capture the existing
app-group base, not a made-up AccountContext singleton:

```swift
let store = ToolsSubtitleStore(directory: URL(fileURLWithPath: context.sharedContext.basePath,
    isDirectory: true).appendingPathComponent("exteraless/gallery-subtitles", isDirectory: true))
ExteralessGallerySubtitleBridge.make = { identity, container in
    let adapter = ExteralessGallerySubtitleAdapter(identity: identity, container: container, store: store)
    return ExteralessGallerySubtitleControls(
        update: { adapter.update(sample: $0) }, visible: { adapter.setVisible($0) },
        layout: { adapter.updateLayout(in: $0, bottomInset: $1) },
        select: { adapter.select(from: $0) }, clear: { adapter.clear(from: $0) },
        dispose: { adapter.dispose() })
}
```

Clear the bridge factory on account teardown. Existing node bindings are disposed
by the lifecycle hooks below. The factory stores a sidecar root only; each node's
identity includes its real account record and media ID.

## `GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift`

### A. Fields on `UniversalVideoGalleryItemNode` (near `playerStatusValue`)

```swift
private var toolsSubtitleIdentity: String?
private var toolsSubtitles: ExteralessGallerySubtitleControls?

private func toolsUpdateSubtitleStatus(_ value: MediaPlayerStatus?) {
    MainActor.assumeIsolated {
        guard let value else { toolsSubtitles?.update(nil); return }
        let playing: Bool
        if case .playing = value.status { playing = true } else { playing = false }
        toolsSubtitles?.update(ToolsSubtitlePlaybackSample(timestamp: value.timestamp,
            generationTimestamp: value.generationTimestamp, duration: value.duration,
            rate: value.baseRate, playing: playing))
    }
}
```

### B. In `setupItem`, directly after the existing `self.item = item` (baseline 2057)

```swift
let subtitleFile: TelegramMediaFile?
if let content = item.content as? NativeVideoContent { subtitleFile = content.fileReference.media }
else if let content = item.content as? HLSVideoContent { subtitleFile = content.fileReference.media }
else { subtitleFile = nil }
let identity = !item.isSecret ? subtitleFile.map {
    "account:\(self.context.account.id.int64):media:\($0.fileId.namespace):\($0.fileId.id)"
} : nil
if identity != self.toolsSubtitleIdentity {
    MainActor.assumeIsolated {
        self.toolsSubtitles?.dispose()
        self.toolsSubtitles = identity.flatMap { ExteralessGallerySubtitleBridge.make?($0, self.view) }
    }
    self.toolsSubtitleIdentity = identity
}
self.toolsUpdateSubtitleStatus(self.playerStatusValue)
MainActor.assumeIsolated { self.toolsSubtitles?.visible(self.isCentral == true && self._isVisible == true) }
```

Ordinary native/HLS videos are admitted. Secret/view-once content keeps its existing
ephemeral lifecycle instead of creating a persistent subtitle sidecar. No video
contents, account DB or copy-protected media are exported by the adapter.

### C. Feed the actual player clock

Inside the current `statusDisposable` callback, just after
`strongSelf.playerStatusValue = value` (baseline 1750):

```swift
strongSelf.toolsUpdateSubtitleStatus(value)
```

Buffering/paused states freeze at the status timestamp; playing extrapolates with
the actual baseRate and CACurrentMediaTime epoch. A seek replaces the sample.

### D. Layout and lifetime

At the end of `containerLayoutUpdated`, after the footer frame is set:

```swift
MainActor.assumeIsolated {
    self.toolsSubtitles?.layout(
        CGRect(x: layout.safeInsets.left, y: navigationBarHeight,
               width: max(0, layout.size.width - layout.safeInsets.left - layout.safeInsets.right),
               height: max(0, layout.size.height - navigationBarHeight)),
        max(layout.intrinsicInsets.bottom, self.areControlsVisible ? self.footerContentNode.frame.height : 0))
}
```

In both `centralityUpdated` and `visibilityUpdated`, after updating their own flags:

```swift
MainActor.assumeIsolated {
    self.toolsSubtitles?.visible(self.isCentral == true && self._isVisible == true && self.pictureInPictureNode == nil)
}
```

In deinit:

```swift
let controls = self.toolsSubtitles
Task { @MainActor in controls?.dispose() }
```

Also hide the binding when transferring ownership to native PiP and restore its
visibility when ownership returns. The overlay is not burned into exported video
and is not falsely advertised as an AVKit PiP subtitle track.

### E. Real settings-menu actions

In `contextMenuMainItems`, after `var items: [ContextMenuItem] = []` and before the
existing `if isSettings` (baseline 3575):

```swift
if isSettings, let controls = strongSelf.toolsSubtitles {
    items.append(.action(ContextMenuActionItem(text: "Choose subtitles…", icon: { _ in nil }, action: { [weak strongSelf] _, done in
        done(.default)
        Queue.mainQueue().after(0.1) {
            guard let presenter = strongSelf?.galleryController() else { return }
            MainActor.assumeIsolated { controls.select(presenter) }
        }
    })))
    items.append(.action(ContextMenuActionItem(text: "Clear external subtitles", icon: { _ in nil }, action: { [weak strongSelf] _, done in
        done(.default)
        guard let presenter = strongSelf?.galleryController() else { return }
        MainActor.assumeIsolated { controls.clear(presenter) }
    })))
}
```

The captured controls belong to the clicked media. Disposal invalidates late picker
and queued menu completions; a swipe to another item cannot attach the file there.

## Acceptance / evidence boundary

Source application is complete; full Apple compile and frames remain pending.
Test ordinary Telegram and HLS videos, 0.5/1/2x playback, pause/buffer/seek, album
swipes, repeated picker cancellation, sidecar persistence, portrait/landscape/Duo,
large text and PiP transfer. Tools model fixtures cover time projection and account
isolation with no network or real player/account effects. A local Files AVPlayer
demo is not reported as proof of these shared-gallery hooks.
