import Foundation
import UIKit
import SwiftSignalKit
import Display
import AnimationCache
import MultiAnimationRenderer
import SubcodecObjC
import SubcodecAnimationCacheImpl
import Accelerate

private let maxSlotsLimit: Int = 882

private func roundUp(_ numToRound: Int, multiple: Int) -> Int {
    if multiple == 0 { return numToRound }
    let remainder = numToRound % multiple
    if remainder == 0 { return numToRound }
    return numToRound + multiple - remainder
}

// Internal renderer seams are exercised with real local sprites by native tests.
final class SpriteContext {
    let mbsPath: String
    var region: SCSpriteRegion
    let targets = Bag<Weak<MultiAnimationRenderTarget>>()
    let metadata: MbsMetadata

    var currentFrameIndex: Int = 0
    var remainingDuration: Double = 0.0
    var hasEmittedFrame = false

    var isPlaying: Bool {
        for target in self.targets.copyItems() {
            if let target = target.value, target.shouldBeAnimating && target.performanceAllowsAnimation {
                return true
            }
        }
        return false
    }

    init(mbsPath: String, region: SCSpriteRegion, metadata: MbsMetadata) {
        self.mbsPath = mbsPath
        self.region = region
        self.metadata = metadata
        let duration = metadata.frameDurations.first ?? 0.0
        self.remainingDuration = duration.isFinite && duration > 0.0 ? duration : 1.0 / 60.0
    }
}

final class SurfaceGroup {
    let spriteWidth: Int
    let spriteHeight: Int

    private(set) var surface: SCMuxSurface?
    private(set) var decoder: SCVideoToolboxDecoder?
    private(set) var spriteContexts: [Int: SpriteContext] = [:]
    private var currentMaxSlots: Int = 64
    // SCVideoToolboxDecoder is a bulk decoder: each call creates a fresh session.
    // Keep a complete, bounded SPS/PPS/IDR + dependent P-frame window, not P-only
    // fragments. Existing MuxSurface.resize supplies periodic I_PCM checkpoints.
    private var streamData = Data()
    private var streamFrames = 1
    private var streamOverflowed = false
    private(set) var lastDecodedFrame: SCDecodedFrame?
    private(set) var failed = false
    private(set) var decodedFrameCount = 0
    private(set) var emittedFrameCount = 0
    private static let maximumStreamBytes = 32 * 1024 * 1024
    private static let maximumDecodedBytes = 64 * 1024 * 1024
    private static let maximumWindowFrames = 8
    private static let maximumWorkFrames = 64
    private static let maximumElapsed = 0.25
    private static let epsilon = 0.0000001

    init(spriteWidth: Int, spriteHeight: Int, initialMaxSlots: Int = 64) {
        self.spriteWidth = spriteWidth
        self.spriteHeight = spriteHeight
        self.currentMaxSlots = max(1, min(maxSlotsLimit, initialMaxSlots))
    }

    func ensureInitialized() -> Bool {
        guard !self.failed else { return false }
        if self.surface != nil {
            return true
        }
        let sink: (Data) -> Void = { [weak self] data in
            self?.appendStream(data)
        }
        guard let surface = try? SCMuxSurface.create(
            withSpriteWidth: Int32(self.spriteWidth),
            spriteHeight: Int32(self.spriteHeight),
            maxSlots: Int32(self.currentMaxSlots),
            qp: 26,
            sink: sink
        ) else {
            return false
        }
        self.surface = surface

        guard !self.streamOverflowed, self.windowFrameLimit() >= 2,
              let decoder = try? SCVideoToolboxDecoder.createDecoder() else {
            self.failed = true
            return false
        }
        self.decoder = decoder

        return true
    }

    func addSprite(mbsPath: String, metadata: MbsMetadata) -> SpriteContext? {
        guard self.ensureInitialized(), let surface = self.surface else {
            return nil
        }

        guard let region = try? surface.addSprite(atPath: mbsPath) else {
            if !self.tryGrow() {
                return nil
            }
            guard let region = try? surface.addSprite(atPath: mbsPath) else {
                return nil
            }
            let context = SpriteContext(mbsPath: mbsPath, region: region, metadata: metadata)
            self.spriteContexts[Int(region.slot)] = context
            return context
        }

        let context = SpriteContext(mbsPath: mbsPath, region: region, metadata: metadata)
        self.spriteContexts[Int(region.slot)] = context
        return context
    }

    func removeSprite(slot: Int) {
        self.surface?.removeSprite(atSlot: Int32(slot))
        self.spriteContexts.removeValue(forKey: slot)
    }

    private func tryGrow() -> Bool {
        let newMaxSlots: Int
        if self.currentMaxSlots * 2 <= maxSlotsLimit {
            newMaxSlots = self.currentMaxSlots * 2
        } else if self.currentMaxSlots < maxSlotsLimit {
            newMaxSlots = maxSlotsLimit
        } else {
            return false
        }

        if self.lastDecodedFrame == nil {
            self.tick(advanceTimestamp: 0.0)
        }
        return self.checkpoint(maxSlots: newMaxSlots)
    }

    private func appendStream(_ data: Data) {
        guard !self.streamOverflowed, data.count <= Self.maximumStreamBytes - self.streamData.count else {
            self.streamOverflowed = true
            return
        }
        self.streamData.append(data)
    }

    private func windowFrameLimit() -> Int {
        guard let surface = self.surface else { return 0 }
        let width = Int64(surface.widthMbs) * 16
        let height = Int64(surface.heightMbs) * 16
        guard width > 0, height > 0, width <= Int64(Self.maximumDecodedBytes) / height else { return 0 }
        let frameBytes = width * height * 3 / 2
        return min(Self.maximumWindowFrames, Int(Int64(Self.maximumDecodedBytes) / max(1, frameBytes)))
    }

    private func decodeWindow() -> Bool {
        guard !self.streamOverflowed, let decoder = self.decoder,
              let frames = try? decoder.decodeStream(self.streamData), frames.count == self.streamFrames,
              let decoded = frames.last else {
            self.failed = true
            return false
        }
        self.lastDecodedFrame = decoded
        self.decodedFrameCount += frames.count
        return true
    }

    private func checkpoint(maxSlots: Int) -> Bool {
        guard !self.failed, let surface = self.surface, let decodedFrame = self.lastDecodedFrame else { return false }
        // resize compacts slots in old-slot order; preserve the context objects so
        // target removal callbacks continue to address their current slot.
        let contexts = self.spriteContexts.keys.sorted().compactMap { self.spriteContexts[$0] }
        self.streamData.removeAll(keepingCapacity: true)
        self.streamFrames = 1
        let yData = decodedFrame.y
        let cbData = decodedFrame.cb
        let crData = decodedFrame.cr
        let decodedWidth = Int(decodedFrame.width)
        let decodedHeight = Int(decodedFrame.height)
        let chromaWidth = decodedWidth / 2

        guard let resizeResult = try? surface.resize(
            toMaxSlots: Int32(maxSlots),
            yPlane: yData,
            cbPlane: cbData,
            crPlane: crData,
            decodedWidth: Int32(decodedWidth),
            decodedHeight: Int32(decodedHeight),
            strideY: Int32(decodedWidth),
            strideCb: Int32(chromaWidth),
            strideCr: Int32(chromaWidth),
            withSink: { [weak self] data in
                self?.appendStream(data)
            }
        ), resizeResult.regions.count == contexts.count else {
            self.failed = true
            return false
        }

        var updatedContexts: [Int: SpriteContext] = [:]
        for (context, region) in zip(contexts, resizeResult.regions) {
            context.region = region
            updatedContexts[Int(region.slot)] = context
        }
        self.spriteContexts = updatedContexts
        self.currentMaxSlots = maxSlots
        guard self.windowFrameLimit() >= 2 else { self.failed = true; return false }
        return self.decodeWindow()
    }

    func tick(advanceTimestamp: Double) {
        guard !self.failed, let surface = self.surface, self.decoder != nil else { return }
        let elapsed = advanceTimestamp.isFinite ? max(0.0, min(Self.maximumElapsed, advanceTimestamp)) : 0.0
        for context in self.spriteContexts.values where context.isPlaying {
            context.remainingDuration = max(-Self.maximumElapsed, context.remainingDuration - elapsed)
        }

        struct Progress {
            let context: SpriteContext
            var index: Int
            var remaining: Double
            var introduced: Bool
        }
        func duration(_ context: SpriteContext, _ index: Int) -> Double {
            guard index >= 0, index < context.metadata.frameDurations.count else { return 1.0 / 60.0 }
            let value = context.metadata.frameDurations[index]
            return value.isFinite && value > 0.0 ? value : 1.0 / 60.0
        }
        func isDue(_ context: SpriteContext) -> Bool {
            return !context.hasEmittedFrame || (context.isPlaying && context.remainingDuration <= Self.epsilon)
        }
        var changed = Set<ObjectIdentifier>()
        var introduced = Set<ObjectIdentifier>()
        var looped = Set<ObjectIdentifier>()
        var rounds = 0
        var decodedWork = 0

        while rounds < Self.maximumWorkFrames && self.spriteContexts.values.contains(where: isDue) {
            if self.streamFrames >= self.windowFrameLimit() {
                guard decodedWork + 1 < Self.maximumWorkFrames else { break }
                guard self.checkpoint(maxSlots: self.currentMaxSlots) else { return }
                decodedWork += 1
            }
            // Each bulk decode includes its dependency window. Count those real
            // decoder frames too, rather than budgeting only a Swift counter.
            let capacity = min(self.windowFrameLimit() - self.streamFrames,
                min(Self.maximumWorkFrames - rounds, Self.maximumWorkFrames - decodedWork - self.streamFrames))
            guard capacity > 0 else { break }
            var progress = self.spriteContexts.mapValues { context in
                Progress(context: context, index: context.currentFrameIndex,
                    remaining: context.remainingDuration, introduced: context.hasEmittedFrame)
            }
            var emitted = 0
            for _ in 0..<capacity {
                let due = progress.keys.sorted().filter { slot in
                    guard let value = progress[slot] else { return false }
                    return !value.introduced || (value.context.isPlaying && value.remaining <= Self.epsilon)
                }
                if due.isEmpty { break }
                for slot in due { surface.advanceSprite(atSlot: Int32(slot)) }
                let before = self.streamData.count
                guard (try? surface.emitFrameIfNeeded(sink: { [weak self] data in self?.appendStream(data) })) != nil,
                      !self.streamOverflowed, self.streamData.count > before else {
                    self.failed = true
                    return
                }
                self.streamFrames += 1
                self.emittedFrameCount += 1
                rounds += 1
                emitted += 1
                // advanceSprite only marks. Exactly this successful emit consumed
                // one source frame for each marked slot (emit, then advance).
                for slot in due {
                    guard var value = progress[slot] else { continue }
                    let id = ObjectIdentifier(value.context)
                    if value.introduced {
                        // Float32 boundary tolerance, not accumulated drift.
                        if value.remaining > 0.0 { value.remaining = 0.0 }
                        value.index += 1
                        if value.index >= value.context.metadata.frameCount {
                            value.index = 0
                            if value.context.metadata.frameCount > 1 { looped.insert(id) }
                        }
                        value.remaining += duration(value.context, value.index)
                    } else {
                        value.introduced = true
                        value.index = 0
                        introduced.insert(id)
                    }
                    changed.insert(id)
                    progress[slot] = value
                }
            }
            guard emitted > 0 else { break }
            guard self.decodeWindow() else { return }
            decodedWork += self.streamFrames
            for value in progress.values {
                value.context.currentFrameIndex = value.index
                value.context.remainingDuration = value.remaining
                value.context.hasEmittedFrame = value.introduced
            }
        }
        // Discard excess stalled time at the work bound. Never advance indices for
        // frames which the mux/decoder did not actually process.
        for context in self.spriteContexts.values where context.hasEmittedFrame && context.remainingDuration <= Self.epsilon {
            context.remainingDuration = duration(context, context.currentFrameIndex)
        }
        guard !changed.isEmpty, let decodedFrame = self.lastDecodedFrame else { return }

        for context in self.spriteContexts.values where changed.contains(ObjectIdentifier(context)) {
            let region = context.region
            let colorRect = region.colorRect
            let alphaRect = region.alphaRect

            let frameWidth = Int(colorRect.width)
            let frameHeight = Int(colorRect.height)
            guard frameWidth > 0 && frameHeight > 0 else {
                continue
            }

            let cgImage = extractCGImage(
                decodedFrame: decodedFrame,
                colorRect: colorRect,
                alphaRect: alphaRect,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )

            let didLoop = looped.contains(ObjectIdentifier(context))

            for targetRef in context.targets.copyItems() {
                if let target = targetRef.value {
                    guard introduced.contains(ObjectIdentifier(context)) || target.contents == nil || (target.shouldBeAnimating && target.performanceAllowsAnimation) else { continue }
                    if let cgImage = cgImage {
                        target.transitionToContents(cgImage, didLoop: didLoop)
                    }
                }
            }
        }
    }

    var isEmpty: Bool {
        return self.spriteContexts.isEmpty
    }

    var hasPlayingSprites: Bool {
        if self.failed { return false }
        for (_, context) in self.spriteContexts {
            if context.isPlaying {
                return true
            }
        }
        return false
    }
}

private func extractCGImage(
    decodedFrame: SCDecodedFrame,
    colorRect: CGRect,
    alphaRect: CGRect,
    frameWidth: Int,
    frameHeight: Int
) -> CGImage? {
    let decodedWidth = Int(decodedFrame.width)
    let chromaWidth = decodedWidth / 2

    let bytesPerRow = frameWidth * 4
    let bufferSize = frameHeight * bytesPerRow
    guard let buffer = malloc(bufferSize) else {
        return nil
    }
    let outPtr = buffer.assumingMemoryBound(to: UInt8.self)

    let colorX = Int(colorRect.origin.x)
    let colorY = Int(colorRect.origin.y)
    let alphaX = Int(alphaRect.origin.x)
    let alphaY = Int(alphaRect.origin.y)

    decodedFrame.y.withUnsafeBytes { yBuf in
        decodedFrame.cb.withUnsafeBytes { cbBuf in
            decodedFrame.cr.withUnsafeBytes { crBuf in
                let yPtr = yBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let cbPtr = cbBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let crPtr = crBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)

                for row in 0 ..< frameHeight {
                    for col in 0 ..< frameWidth {
                        let srcY = yPtr[(colorY + row) * decodedWidth + (colorX + col)]
                        let srcCb = cbPtr[((colorY + row) / 2) * chromaWidth + ((colorX + col) / 2)]
                        let srcCr = crPtr[((colorY + row) / 2) * chromaWidth + ((colorX + col) / 2)]
                        let srcA = yPtr[(alphaY + row) * decodedWidth + (alphaX + col)]

                        let yVal = Int(srcY) - 16
                        let cbVal = Int(srcCb) - 128
                        let crVal = Int(srcCr) - 128

                        var r = (298 * yVal + 459 * crVal + 128) >> 8
                        var g = (298 * yVal - 55 * cbVal - 136 * crVal + 128) >> 8
                        var b = (298 * yVal + 541 * cbVal + 128) >> 8

                        r = max(0, min(255, r))
                        g = max(0, min(255, g))
                        b = max(0, min(255, b))

                        let a = Int(srcA)
                        let pr = (r * a + 127) / 255
                        let pg = (g * a + 127) / 255
                        let pb = (b * a + 127) / 255

                        let outOffset = (row * frameWidth + col) * 4
                        outPtr[outOffset + 0] = UInt8(pb)
                        outPtr[outOffset + 1] = UInt8(pg)
                        outPtr[outOffset + 2] = UInt8(pr)
                        outPtr[outOffset + 3] = UInt8(a)
                    }
                }
            }
        }
    }

    guard let dataProvider = CGDataProvider(dataInfo: nil, data: buffer, size: bufferSize, releaseData: { _, data, _ in
        free(UnsafeMutableRawPointer(mutating: data))
    }) else {
        free(buffer)
        return nil
    }

    return CGImage(
        width: frameWidth,
        height: frameHeight,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
        provider: dataProvider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

public final class SubcodecMultiAnimationRendererImpl: MultiAnimationRenderer {
    private struct SizeKey: Hashable {
        let width: Int
        let height: Int
    }

    private var surfaceGroups: [SizeKey: SurfaceGroup] = [:]
    private lazy var performanceClock = ToolsPerformanceRenderClock { [weak self] interval in
        self?.animationTick(frameInterval: interval)
    }

    private(set) var isPlaying: Bool = false {
        didSet {
            if self.isPlaying != oldValue {
                self.performanceClock.setPlaying(self.isPlaying)
            }
        }
    }

    public init() {}

    public func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, unique: Bool, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Disposable {
        guard let subcodecCache = cache as? SubcodecAnimationCacheImpl else {
            return EmptyDisposable
        }

        let spriteWidth = roundUp(Int(size.width), multiple: 16)
        let spriteHeight = roundUp(Int(size.height), multiple: 16)
        let sizeKey = SizeKey(width: spriteWidth, height: spriteHeight)

        let fetchDisposable = MetaDisposable()

        fetchDisposable.set(subcodecCache.fetchIfNeeded(sourceId: itemId, size: size, fetch: fetch, completion: { [weak self, weak target] mbsPath in
            Queue.mainQueue().async {
                guard let strongSelf = self, let target = target, let mbsPath = mbsPath else {
                    return
                }

                guard let metadata = subcodecCache.loadMetadata(sourceId: itemId, size: size) else {
                    return
                }

                let surfaceGroup: SurfaceGroup
                if let existing = strongSelf.surfaceGroups[sizeKey] {
                    surfaceGroup = existing
                } else {
                    surfaceGroup = SurfaceGroup(spriteWidth: spriteWidth, spriteHeight: spriteHeight)
                    strongSelf.surfaceGroups[sizeKey] = surfaceGroup
                }

                guard let spriteContext = surfaceGroup.addSprite(mbsPath: mbsPath, metadata: metadata) else {
                    return
                }

                let targetIndex = spriteContext.targets.add(Weak(target))
                target.numFrames = metadata.frameCount

                let deinitIndex = target.deinitCallbacks.add { [weak self, weak surfaceGroup] in
                    Queue.mainQueue().async {
                        guard let strongSelf = self, let surfaceGroup = surfaceGroup else {
                            return
                        }
                        spriteContext.targets.remove(targetIndex)
                        if spriteContext.targets.isEmpty {
                            surfaceGroup.removeSprite(slot: Int(spriteContext.region.slot))
                            if surfaceGroup.isEmpty {
                                strongSelf.surfaceGroups.removeValue(forKey: sizeKey)
                            }
                            strongSelf.updateIsPlaying()
                        }
                    }
                }

                let updateStateIndex = target.updateStateCallbacks.add { [weak self] in
                    self?.updateIsPlaying()
                }

                fetchDisposable.set(ActionDisposable { [weak self, weak surfaceGroup, weak target] in
                    guard let strongSelf = self, let surfaceGroup = surfaceGroup else {
                        return
                    }
                    if let target = target {
                        target.deinitCallbacks.remove(deinitIndex)
                        target.updateStateCallbacks.remove(updateStateIndex)
                    }
                    spriteContext.targets.remove(targetIndex)
                    if spriteContext.targets.isEmpty {
                        surfaceGroup.removeSprite(slot: Int(spriteContext.region.slot))
                        if surfaceGroup.isEmpty {
                            strongSelf.surfaceGroups.removeValue(forKey: sizeKey)
                        }
                        strongSelf.updateIsPlaying()
                    }
                })

                strongSelf.updateIsPlaying()
            }
        }))

        return ActionDisposable {
            fetchDisposable.dispose()
        }.strict()
    }

    public func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool {
        if let item = cache.getFirstFrameSynchronously(sourceId: itemId, size: size) {
            guard let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) else {
                return false
            }
            switch frame.frame.format {
            case let .rgba(data, width, height, bytesPerRow):
                guard let context = DrawingContext(size: CGSize(width: CGFloat(width), height: CGFloat(height)), scale: 1.0, opaque: false, bytesPerRow: bytesPerRow) else {
                    return false
                }
                data.withUnsafeBytes { bytes -> Void in
                    memcpy(context.bytes, bytes.baseAddress!, height * bytesPerRow)
                }
                guard let image = context.generateImage() else {
                    return false
                }
                target.contents = image.cgImage
                target.numFrames = item.numFrames
                return true
            default:
                return false
            }
        }
        return false
    }

    public func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (Bool, Bool) -> Void) -> Disposable {
        return cache.getFirstFrame(queue: .mainQueue(), sourceId: itemId, size: size, fetch: fetch, completion: { [weak target] result in
            guard let item = result.item else {
                Queue.mainQueue().async {
                    completion(false, result.isFinal)
                }
                return
            }

            let loaded: Bool
            if let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) {
                switch frame.frame.format {
                case let .rgba(data, width, height, bytesPerRow):
                    Queue.mainQueue().async {
                        guard let target = target else {
                            completion(false, true)
                            return
                        }
                        target.numFrames = item.numFrames
                        if let context = DrawingContext(size: CGSize(width: CGFloat(width), height: CGFloat(height)), scale: 1.0, opaque: false, bytesPerRow: bytesPerRow) {
                            data.withUnsafeBytes { bytes -> Void in
                                memcpy(context.bytes, bytes.baseAddress!, height * bytesPerRow)
                            }
                            if let image = context.generateImage() {
                                target.contents = image.cgImage
                                completion(true, true)
                                return
                            }
                        }
                        completion(false, true)
                    }
                    return
                default:
                    loaded = false
                }
            } else {
                loaded = false
            }

            Queue.mainQueue().async {
                completion(loaded, true)
            }
        }).strict()
    }

    public func loadFirstFrameAsImage(cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (CGImage?) -> Void) -> Disposable {
        return cache.getFirstFrame(queue: .mainQueue(), sourceId: itemId, size: size, fetch: fetch, completion: { result in
            guard let item = result.item else {
                Queue.mainQueue().async {
                    completion(nil)
                }
                return
            }

            if let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) {
                switch frame.frame.format {
                case let .rgba(data, width, height, bytesPerRow):
                    Queue.mainQueue().async {
                        if let context = DrawingContext(size: CGSize(width: CGFloat(width), height: CGFloat(height)), scale: 1.0, opaque: false, bytesPerRow: bytesPerRow) {
                            data.withUnsafeBytes { bytes -> Void in
                                memcpy(context.bytes, bytes.baseAddress!, height * bytesPerRow)
                            }
                            completion(context.generateImage()?.cgImage)
                        } else {
                            completion(nil)
                        }
                    }
                    return
                default:
                    break
                }
            }

            Queue.mainQueue().async {
                completion(nil)
            }
        }).strict()
    }

    public func setFrameIndex(itemId: String, size: CGSize, frameIndex: Int, placeholder: UIImage) {
    }

    private func updateIsPlaying() {
        var isPlaying = false
        for (_, group) in self.surfaceGroups {
            if group.hasPlayingSprites {
                isPlaying = true
                break
            }
        }
        self.isPlaying = isPlaying
    }

    private func animationTick(frameInterval: Double) {
        for (_, group) in self.surfaceGroups {
            if group.hasPlayingSprites {
                group.tick(advanceTimestamp: frameInterval)
            }
        }
        self.updateIsPlaying()
    }
}
