import AVFoundation
import ExteralessCore
import Foundation
import ICloudResources
import SwiftSignalKit
import TelegramCore

/// A selected native file remains a document if its metadata cannot be loaded.
/// This only adds a Video attribute; no send plan, caption or album is rebuilt.
func exteralessMP4FileDescription(_ url: URL) -> Signal<(ICloudFileDescription?, TelegramMediaFileAttribute?), NoError> {
    return iCloudFileDescription(url)
    |> mapToSignal { item -> Signal<(ICloudFileDescription?, TelegramMediaFileAttribute?), NoError> in
        guard let item, (item.fileName as NSString).pathExtension.lowercased() == "mp4",
              ClientSettings.shared.bool("chats.sendMp4DocumentAsVideo", default: true) else { return .single((item, nil)) }
        return exteralessMP4VideoAttribute(url: url) |> map { (item, $0) }
    }
}

private func exteralessMP4VideoAttribute(url: URL) -> Signal<TelegramMediaFileAttribute?, NoError> {
    return Signal { subscriber in
        let scoped = url.startAccessingSecurityScopedResource()
        let closed = Atomic(value: false)
        let cancelled = Atomic(value: false)
        let asset = AVURLAsset(url: url)
        let keys = ["tracks", "duration", "playable"]
        func close() {
            if !closed.swap(true), scoped { url.stopAccessingSecurityScopedResource() }
        }
        asset.loadValuesAsynchronously(forKeys: keys) {
            defer { close() }
            guard !cancelled.with({ $0 }) else { return }
            var attribute: TelegramMediaFileAttribute?
            if keys.allSatisfy({ asset.statusOfValue(forKey: $0, error: nil) == .loaded }), asset.isPlayable,
               let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let width = abs(size.width), height = abs(size.height)
                let duration = CMTimeGetSeconds(asset.duration)
                if width.isFinite, height.isFinite, duration.isFinite, duration > 0,
                   width >= 1, height >= 1, width <= 32768, height <= 32768 {
                    attribute = .Video(duration: duration, size: PixelDimensions(width: Int32(width), height: Int32(height)), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)
                }
            }
            subscriber.putNext(attribute)
            subscriber.putCompletion()
        }
        return ActionDisposable {
            _ = cancelled.swap(true)
            asset.cancelLoading()
            close()
        }
    }
    |> timeout(5.0, queue: .mainQueue(), alternate: .single(nil))
}
