import AVFoundation
import Foundation
import ImageIO
import PluginHost
import TelegramCore
import UniformTypeIdentifiers

/// File reads/photo decoding are serial and bounded. Asset metadata loads are
/// asynchronous and have both a request deadline and cancelLoading on cancellation.
final class PluginTLMediaPreparation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Exteraless.TLMediaPreparation", qos: .userInitiated)
    private static let maximumFileBytes = 32 * 1024 * 1024

    func prepare(model: PluginTLMediaModel, source: PluginResourcePath, cacheDirectory: URL,
                 isActive: @escaping @Sendable () -> Bool,
                 bindCancellation: @escaping (@escaping () -> Void) -> Void) async throws -> ExteralessTLPreparedMedia {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    guard isActive() else { throw CancellationError() }
                    let admittedURL = try source.validatedURL()
                    let attributes = try FileManager.default.attributesOfItem(atPath: admittedURL.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                          size.int64Value <= Int64(Self.maximumFileBytes) else {
                        throw ExteralessTLError(.malformed, "sendMedia: source must be a regular local file of 1...32 MiB")
                    }
                    guard isActive() else { throw CancellationError() }
                    let file = try FileHandle(forReadingFrom: admittedURL)
                    defer { try? file.close() }
                    var result = Data()
                    while true {
                        guard isActive() else { throw CancellationError() }
                        let chunk = try file.read(upToCount: min(1024 * 1024, Self.maximumFileBytes + 1 - result.count)) ?? Data()
                        if chunk.isEmpty { break }
                        result.append(chunk)
                        guard result.count <= Self.maximumFileBytes else {
                            throw ExteralessTLError(.limit, "sendMedia: file grew beyond 32 MiB")
                        }
                    }
                    guard !result.isEmpty else { throw ExteralessTLError(.malformed, "sendMedia: empty file") }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard isActive(), !Task.isCancelled else { throw CancellationError() }
        let sourceURL = source.url
        if model.kind == .photo {
            return try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    do {
                        guard isActive() else { throw CancellationError() }
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
                              width.doubleValue > 0, height.doubleValue > 0,
                              width.doubleValue <= 32768, height.doubleValue <= 32768,
                              width.doubleValue * height.doubleValue <= 64_000_000 else {
                            throw ExteralessTLError(.unsupported, "sendMedia.photo: unsupported/animated/oversized image")
                        }
                        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280,
                            kCGImageSourceShouldCacheImmediately: true]
                        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                            throw ExteralessTLError(.malformed, "sendMedia.photo: native decode failed")
                        }
                        let jpeg = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                            throw ExteralessTLError(.malformed, "sendMedia.photo: native JPEG encoder unavailable")
                        }
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else {
                            throw ExteralessTLError(.malformed, "sendMedia.photo: native JPEG encoding failed")
                        }
                        guard isActive() else { throw CancellationError() }
                        continuation.resume(returning: try ExteralessTLPreparedMedia(kind: .photo, data: jpeg as Data,
                            fileName: "photo.jpg", mimeType: "image/jpeg", width: Int32(image.width), height: Int32(image.height)))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        let fileName = model.fileName ?? sourceURL.lastPathComponent
        let inferredMime = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let mimeType = model.mimeType ?? inferredMime
        if model.kind == .document {
            return try ExteralessTLPreparedMedia(kind: .document, data: data, fileName: fileName, mimeType: mimeType)
        }
        if model.kind == .video, !["mp4", "mov", "m4v"].contains(sourceURL.pathExtension.lowercased()) {
            throw ExteralessTLError(.unsupported, "sendMedia.video: native video upload supports mp4/mov/m4v; use document for other containers")
        }
        guard (model.kind == .audio && mimeType.hasPrefix("audio/")) || (model.kind == .video && mimeType.hasPrefix("video/")) else {
            throw ExteralessTLError(.malformed, "sendMedia: MIME type does not match audio/video kind")
        }
        // Inspect an owned copy of the exact bytes that will be uploaded. A plugin
        // may delete/change its source immediately after the bridge call returns.
        let staged = cacheDirectory.appendingPathComponent("tl-inspect-\(UUID().uuidString)").appendingPathExtension(sourceURL.pathExtension)
        defer { try? FileManager.default.removeItem(at: staged) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                do {
                    guard isActive() else { throw CancellationError() }
                    try data.write(to: staged, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard isActive(), !Task.isCancelled else { throw CancellationError() }
        let asset = AVURLAsset(url: staged)
        bindCancellation {
            asset.cancelLoading()
        }
        defer { asset.cancelLoading() }
        let duration = try await asset.load(.duration).seconds
        guard isActive(), !Task.isCancelled else { throw CancellationError() }
        if model.kind == .audio {
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw ExteralessTLError(.unsupported, "sendMedia.audio: AVFoundation cannot inspect this audio file")
            }
            guard isActive(), !Task.isCancelled else { throw CancellationError() }
            return try ExteralessTLPreparedMedia(kind: .audio, data: data, fileName: fileName, mimeType: mimeType, duration: duration)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExteralessTLError(.unsupported, "sendMedia.video: native video track is unavailable")
        }
        guard isActive(), !Task.isCancelled else { throw CancellationError() }
        let naturalSize = try await track.load(.naturalSize)
        guard isActive(), !Task.isCancelled else { throw CancellationError() }
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let width = abs(Double(size.width)).rounded()
        let height = abs(Double(size.height)).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 32768, height <= 32768,
              isActive(), !Task.isCancelled else {
            throw ExteralessTLError(.malformed, "sendMedia.video: invalid native dimensions or cancelled inspection")
        }
        return try ExteralessTLPreparedMedia(kind: .video, data: data, fileName: fileName, mimeType: mimeType,
            width: Int32(width), height: Int32(height), duration: duration)
    }
}
