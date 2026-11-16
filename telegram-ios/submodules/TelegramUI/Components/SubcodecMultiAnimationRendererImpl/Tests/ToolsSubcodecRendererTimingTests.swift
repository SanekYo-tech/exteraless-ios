import CoreGraphics
import ExteralessCore
import Foundation
import MultiAnimationRenderer
import SubcodecAnimationCacheImpl
import SubcodecObjC
import SwiftSignalKit
import UIKit
import XCTest
@testable import SubcodecMultiAnimationRendererImpl

private final class SubcodecTimingTarget: MultiAnimationRenderTarget {
    var samples: [Int] = []
    var loopCount = 0

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        XCTAssertEqual(CFGetTypeID(contents), CGImage.typeID)
        guard CFGetTypeID(contents) == CGImage.typeID else { return }
        let image = contents as! CGImage
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        samples.append(Int(pixel[0]))
        if didLoop { loopCount += 1 }
        self.contents = contents
    }
}

/// Actual SurfaceGroup -> SCMuxSurface -> SCVideoToolboxDecoder. The independent
/// reference uses one mark/emit per frame and SCOpenH264Decoder on the same MBS.
@MainActor
final class ToolsSubcodecRendererTimingTests: XCTestCase {
    private struct SpriteFixture {
        let path: String
        let metadata: MbsMetadata
        let referenceY: [Int]
    }

    private func sprite(durations: [Double] = Array(repeating: 1.0 / 60.0, count: 7)) throws -> SpriteFixture {
        executionTimeAllowance = 30
        let previous = ToolsPerformancePolicyStore.shared.snapshot()?.input
        let enabled = allowed()
        ToolsPerformancePolicyStore.shared.publish(enabled)
        addTeardownBlock { ToolsPerformancePolicyStore.shared.publish(previous ?? enabled) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pnp-subcodec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = SubcodecAnimationCacheImpl(basePath: root.path,
            allocateTempFile: { root.appendingPathComponent(UUID().uuidString).path }, updateStorageStats: { _, _ in })
        let size = CGSize(width: 16, height: 16)
        let path = cache.getMbsPath(sourceId: "fixture", size: size)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let extractor = try SCSprite.extractor(withSpriteSize: 16, qp: 26, outputPath: path)
        for index in durations.indices {
            try extractor.addFrameY(Data(repeating: UInt8(32 + index * 32), count: 16 * 16), yStride: 16,
                cb: Data(repeating: 128, count: 8 * 8), cbStride: 8,
                cr: Data(repeating: 128, count: 8 * 8), crStride: 8,
                alpha: Data(repeating: 255, count: 16 * 16), alphaStride: 16)
        }
        try extractor.finalizeExtraction()
        var metadataBytes = Data()
        var count = UInt32(durations.count).littleEndian
        withUnsafeBytes(of: &count) { metadataBytes.append(contentsOf: $0) }
        for duration in durations {
            var bits = Float32(duration).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { metadataBytes.append(contentsOf: $0) }
        }
        try metadataBytes.write(to: URL(fileURLWithPath: cache.getMetaPath(sourceId: "fixture", size: size)))
        let metadata = try XCTUnwrap(cache.loadMetadata(sourceId: "fixture", size: size))
        XCTAssertEqual(metadata.frameCount, durations.count)

        var bytes = Data()
        let reference = try SCMuxSurface.create(withSpriteWidth: 16, spriteHeight: 16, maxSlots: 1, qp: 26, sink: { bytes.append($0) })
        let region = try reference.addSprite(atPath: path)
        for _ in durations {
            reference.advanceSprite(atSlot: region.slot)
            try reference.emitFrameIfNeeded(sink: { bytes.append($0) })
        }
        let decoded = try SCOpenH264Decoder.createDecoder().decodeStream(bytes)
        XCTAssertEqual(decoded.count, durations.count + 1, "IDR plus the real sprite frames")
        guard decoded.count == durations.count + 1 else { throw FixtureError.incompleteReference }
        let pixels = decoded.dropFirst().map { sample($0, region: region) }
        XCTAssertEqual(Set(pixels).count, durations.count, "Source frames must be visually distinguishable")
        return SpriteFixture(path: path, metadata: metadata, referenceY: pixels)
    }

    private func allowed(loopStickers: Bool = true) -> ToolsPerformancePolicy.Input {
        .init(selection: .init(mode: .high),
            nativeEnergy: .init(autoplayVideo: true, autoplayGif: true, loopStickers: loopStickers, loopEmoji: true,
                fullTranslucency: true, extendBackgroundWork: false, autodownloadInBackground: false),
            environment: .init(isInForeground: true, lowPowerMode: false, batterySaving: false, thermal: .nominal),
            automaticFramesPerSecond: 60, maximumFramesPerSecond: 60)
    }

    private func attach(_ sprite: SpriteFixture, to group: SurfaceGroup, playing: Bool = true) throws -> (SpriteContext, SubcodecTimingTarget) {
        let context = try XCTUnwrap(group.addSprite(mbsPath: sprite.path, metadata: sprite.metadata))
        let target = SubcodecTimingTarget()
        target.shouldBeAnimating = playing
        _ = context.targets.add(Weak(target))
        return (context, target)
    }

    private func sample(_ frame: SCDecodedFrame, region: SCSpriteRegion) -> Int {
        let x = Int(region.colorRect.midX)
        let y = Int(region.colorRect.midY)
        return Int(frame.y[y * Int(frame.width) + x])
    }

    private func assertFrame(_ expected: Int, sprite: SpriteFixture, group: SurfaceGroup, context: SpriteContext,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(group.failed, file: file, line: line)
        let decoded = try XCTUnwrap(group.lastDecodedFrame, file: file, line: line)
        let pixel = sample(decoded, region: context.region)
        XCTAssertLessThanOrEqual(abs(pixel - sprite.referenceY[expected]), 1, "Real VideoToolbox pixels", file: file, line: line)
        XCTAssertEqual(context.currentFrameIndex, expected, "Metadata agrees with the actual decoded sprite", file: file, line: line)
    }

    func testPNP03ThirtyAndSixtyHzDeliverCorrectDecodedFramesAndLoopBoundaries() throws {
        let sprite = try sprite()
        for fps in [30, 60] {
            let group = SurfaceGroup(spriteWidth: 16, spriteHeight: 16, initialMaxSlots: 1)
            let (context, target) = try attach(sprite, to: group)
            group.tick(advanceTimestamp: 0)
            try assertFrame(0, sprite: sprite, group: group, context: context)
            for tick in 1...18 {
                let emittedBefore = group.emittedFrameCount
                let decodedBefore = group.decodedFrameCount
                let deliveredBefore = target.samples.count
                group.tick(advanceTimestamp: 1.0 / Double(fps))
                let frames = tick * (60 / fps)
                try assertFrame(frames % 7, sprite: sprite, group: group, context: context)
                XCTAssertEqual(group.emittedFrameCount - emittedBefore, 60 / fps, "N marks must have N actual emits")
                XCTAssertLessThanOrEqual(group.decodedFrameCount - decodedBefore, 64)
                XCTAssertEqual(target.samples.count - deliveredBefore, 1, "Deliver only the final image of the tick")
                XCTAssertEqual(target.loopCount, frames / 7)
            }
        }
    }

    func testPNP03SharedSpriteKeepsTheVetoedTargetStillWhileAllowedTargetAdvances() throws {
        let sprite = try sprite()
        let group = SurfaceGroup(spriteWidth: 16, spriteHeight: 16, initialMaxSlots: 1)
        let (context, active) = try attach(sprite, to: group)
        let vetoed = SubcodecTimingTarget()
        vetoed.shouldBeAnimating = true
        vetoed.performanceAnimationKind = .sticker
        _ = context.targets.add(Weak(vetoed))
        group.tick(advanceTimestamp: 0)
        let previous = ToolsPerformancePolicyStore.shared.snapshot()?.input
        let enabled = allowed()
        defer { ToolsPerformancePolicyStore.shared.publish(previous ?? enabled) }
        ToolsPerformancePolicyStore.shared.publish(allowed(loopStickers: false))
        let frozen = vetoed.samples
        group.tick(advanceTimestamp: 1.0 / 30.0)
        try assertFrame(2, sprite: sprite, group: group, context: context)
        XCTAssertEqual(vetoed.samples, frozen)
        XCTAssertNotEqual(active.samples.last, frozen.last)
        XCTAssertTrue(vetoed.shouldBeAnimating)
    }

    func testPNP03CheckpointCompactionPreservesPausedPixelsAndLiveContextIdentity() throws {
        let sprite = try sprite()
        let group = SurfaceGroup(spriteWidth: 16, spriteHeight: 16, initialMaxSlots: 4)
        let (removed, removedTarget) = try attach(sprite, to: group)
        let (paused, pausedTarget) = try attach(sprite, to: group, playing: false)
        let (active, activeTarget) = try attach(sprite, to: group)
        group.tick(advanceTimestamp: 0)
        group.removeSprite(slot: Int(removed.region.slot))
        let pausedSamples = pausedTarget.samples
        for tick in 1...10 {
            group.tick(advanceTimestamp: 1.0 / 30.0)
            try assertFrame((tick * 2) % 7, sprite: sprite, group: group, context: active)
            try assertFrame(0, sprite: sprite, group: group, context: paused)
        }
        XCTAssertTrue(group.spriteContexts[Int(active.region.slot)] === active)
        XCTAssertTrue(group.spriteContexts[Int(paused.region.slot)] === paused)
        XCTAssertEqual(active.region.slot, 1, "The native resize compacted the hole")
        XCTAssertEqual(pausedTarget.samples, pausedSamples)
        XCTAssertEqual(activeTarget.samples.count, 11)
        XCTAssertEqual(removedTarget.samples.count, 1)
        group.removeSprite(slot: Int(active.region.slot))
        XCTAssertNil(group.spriteContexts[Int(active.region.slot)])
    }

    func testPNP03LargeElapsedAndTinyDurationsStayWithinActualDecoderWorkBound() throws {
        let sprite = try sprite()
        let group = SurfaceGroup(spriteWidth: 16, spriteHeight: 16, initialMaxSlots: 1)
        let (context, target) = try attach(sprite, to: group)
        group.tick(advanceTimestamp: 0)
        let before = group.decodedFrameCount
        group.tick(advanceTimestamp: 3_600)
        try assertFrame(15 % 7, sprite: sprite, group: group, context: context)
        XCTAssertLessThanOrEqual(group.decodedFrameCount - before, 64)
        XCTAssertEqual(target.samples.count, 2)

        let tiny = try self.sprite(durations: Array(repeating: 0.000001, count: 7))
        let limited = SurfaceGroup(spriteWidth: 16, spriteHeight: 16, initialMaxSlots: 1)
        let (tinyContext, tinyTarget) = try attach(tiny, to: limited)
        limited.tick(advanceTimestamp: 0)
        let emitted = limited.emittedFrameCount
        let decoded = limited.decodedFrameCount
        limited.tick(advanceTimestamp: 0.25)
        XCTAssertLessThanOrEqual(limited.decodedFrameCount - decoded, 64)
        XCTAssertLessThanOrEqual(limited.emittedFrameCount - emitted, 64)
        try assertFrame((limited.emittedFrameCount - emitted) % 7, sprite: tiny, group: limited, context: tinyContext)
        XCTAssertEqual(tinyTarget.samples.count, 2)
    }

    private enum FixtureError: Error { case incompleteReference }
}
