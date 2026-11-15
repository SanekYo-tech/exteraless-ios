import AppBundle
import Compression
import ExteralessCore
import Foundation
import ImageIO
import Svg
import UIKit

private final class ExteralessIconImages: @unchecked Sendable {
    let values: [String: UIImage]
    init(_ values: [String: UIImage]) { self.values = values }
}

/// Immutable UIImage instances are decoded once on a worker and read under a
/// lock. The AppBundle hook can be called by Telegram's async drawing queues.
private final class ExteralessIconCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]

    func image(_ name: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[name]
    }

    func replace(_ values: [String: UIImage]) {
        lock.lock()
        images = values
        lock.unlock()
    }
}

@MainActor
final class ExteralessIconPacks {
    static let shared = ExteralessIconPacks()
    let store: AppearanceIconPackStore
    private let cache = ExteralessIconCache()
    private var generation: UInt64 = 0
    private var reloadTask: Task<Void, Never>?
    private var active = false
    private(set) var errorText: String?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.store = AppearanceIconPackStore(directory: support.appendingPathComponent("exteraless/icon-packs", isDirectory: true))
    }

    func start() {
        self.active = true
        let cache = self.cache
        setExteralessAppBundleImageProvider { name in cache.image(name) }
        self.reload()
    }

    func stop() {
        self.active = false
        self.generation &+= 1
        self.reloadTask?.cancel()
        self.reloadTask = nil
        self.cache.replace([:])
        setExteralessAppBundleImageProvider(nil)
    }

    func reload() {
        guard self.active else { return }
        self.generation &+= 1
        let generation = self.generation
        self.reloadTask?.cancel()
        let settings = ClientSettings.shared
        let enabled = settings.bool("appearance.enabled")
        let ids = AppearanceIconPackPolicy.activeIds(settings.string("appearance.activePacks"))
        let base = settings.integer("appearance.iconReplacements")
        let store = self.store
        self.reloadTask = Task { [weak self] in
            do {
                var packs: [AppearanceIconPackMetadata] = []
                var files: [String: [String: Data]] = [:]
                if enabled && !ids.isEmpty {
                    packs = try await store.list()
                    for id in ids where packs.contains(where: { $0.packId == id }) {
                        try Task.checkCancellation()
                        files[id] = try await store.iconFiles(id: id)
                    }
                }
                try Task.checkCancellation()
                let owners = AppearanceIconPackPolicy.owners(activeIds: ids, packs: packs, enabled: enabled)
                let capturedPacks = packs
                let capturedFiles = files
                let decodeTask = Task.detached(priority: .userInitiated) {
                    var images: [String: UIImage] = [:]
                    for mapping in AppearanceIconNames.mappings {
                        if Task.isCancelled { break }
                        var replacement: UIImage?
                        // The original drawable name remains the cross-platform key.
                        // An exact iOS asset override is also accepted in native packs.
                        if let id = owners[mapping.asset], let metadata = capturedPacks.first(where: { $0.packId == id }),
                           let path = metadata.icons[mapping.asset] ?? metadata.icons[mapping.android], let data = capturedFiles[id]?[path] {
                            replacement = Self.decodeImage(data, fileExtension: (path as NSString).pathExtension)
                        }
                        if replacement == nil && (base == 1 || base == 2) {
                            replacement = UIImage(systemName: mapping.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: base == 1 ? .regular : .light))
                        }
                        if let replacement { images[mapping.asset] = Self.sizedIcon(replacement) }
                    }
                    return ExteralessIconImages(images)
                }
                let decoded = await withTaskCancellationHandler(operation: { await decodeTask.value }, onCancel: { decodeTask.cancel() })
                guard !Task.isCancelled, let self, self.active, self.generation == generation else { return }
                self.errorText = nil
                self.cache.replace(decoded.values)
                NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.errorText = error.localizedDescription
                self.cache.replace([:])
                NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
            }
        }
    }

    func importArchive(at url: URL) async throws -> AppearanceIconPackMetadata {
        let bytes = try await Self.readPickedFile(url, maximum: AppearanceIconArchive.maximumArchiveBytes)
        // Reject a mapped image that cannot render before committing its pack.
        try await Task.detached(priority: .userInitiated) {
            let (metadata, files) = try AppearanceIconArchive.unpack(AppearanceIconArchive.decode(bytes, inflate: Self.inflate))
            for (resource, path) in metadata.icons where AppearanceIconNames.mapping(for: resource) != nil {
                guard let image = files[path], Self.decodeImage(image, fileExtension: (path as NSString).pathExtension) != nil else {
                    throw AppearanceIconPackError.unsupportedImage
                }
            }
        }.value
        let metadata = try await self.store.install(archive: bytes, inflate: Self.inflate)
        self.reload()
        return metadata
    }

    func replaceIcon(packId: String, resource: String, url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        let bytes = try await Self.readPickedFile(url, maximum: AppearanceIconArchive.maximumFileBytes)
        let valid = await Task.detached(priority: .userInitiated) { Self.decodeImage(bytes, fileExtension: ext) != nil }.value
        guard valid else { throw AppearanceIconPackError.unsupportedImage }
        try await self.store.replaceIcon(id: packId, resource: resource, data: bytes, fileExtension: ext)
        self.reload()
    }

    nonisolated static func readPickedFile(_ url: URL, maximum: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let count = size.fileSize, count <= maximum else { throw AppearanceIconPackError.sizeLimit }
            let data = try Data(contentsOf: url)
            guard data.count <= maximum else { throw AppearanceIconPackError.sizeLimit }
            return data
        }.value
    }

    nonisolated static func inflate(_ data: Data, _ size: Int) throws -> Data {
        guard size <= AppearanceIconArchive.maximumFileBytes else { throw AppearanceIconPackError.sizeLimit }
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress, let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, size + 1, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw AppearanceIconPackError.invalidArchive }
        output.count = size
        return output
    }

    nonisolated private static func decodeImage(_ data: Data, fileExtension ext: String) -> UIImage? {
        if ext.lowercased() == "svg" {
            guard data.count <= 512 * 1024, let xml = String(data: data, encoding: .utf8),
                  !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY"),
                  !xml.localizedCaseInsensitiveContains("<image"), !xml.localizedCaseInsensitiveContains("<script") else { return nil }
            return drawSvgImage(data: data, size: CGSize(width: 28, height: 28), backgroundColor: nil, foregroundColor: .black, scale: 3, opaque: false)
        }
        guard ["png", "jpg", "jpeg", "webp"].contains(ext.lowercased()),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 4096, height.intValue <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 84, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: 3, orientation: .up)
    }

    nonisolated private static func sizedIcon(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format)
        return renderer.image { _ in
            let factor = min(28 / max(1, image.size.width), 28 / max(1, image.size.height))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            image.withRenderingMode(.alwaysOriginal).draw(in: CGRect(x: (28 - size.width) * 0.5, y: (28 - size.height) * 0.5, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysTemplate)
    }
}
