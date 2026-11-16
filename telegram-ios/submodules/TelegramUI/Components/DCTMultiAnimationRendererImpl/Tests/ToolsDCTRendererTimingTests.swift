import AnimationCache
import CoreGraphics
import DCTAnimationCacheImpl
import ExteralessCore
import Foundation
import MultiAnimationRenderer
import SwiftSignalKit
import UIKit
import XCTest
@testable import DCTMultiAnimationRendererImpl

private final class DCTTimingTarget: MultiAnimationRenderTarget {
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

/// The production ItemAnimationContext and DCTAnimationCacheImpl writer/accessor.
/// Only worker admission/completion is controlled; no substitute frame planner.
@MainActor
final class ToolsDCTRendererTimingTests: XCTestCase {
    private struct Fixture {
        let context: ItemAnimationContext
        let target: DCTTimingTarget
        let reference: [Int]

        func tick(_ elapsed: Double) { context.animationTick(advanceTimestamp: elapsed)?.task()() }
        func index() throws -> Int {
            let sample = try XCTUnwrap(target.samples.last)
            let index = try XCTUnwrap(reference.indices.min(by: { abs(reference[$0] - sample) < abs(reference[$1] - sample) }))
            XCTAssertLessThanOrEqual(abs(reference[index] - sample), 2)
            return index
        }
    }

    private func fixture(durations: [Double] = Array(repeating: 1.0 / 60.0, count: 7)) throws -> Fixture {
        executionTimeAllowance = 30
        let previous = ToolsPerformancePolicyStore.shared.snapshot()?.input
        let enabled = ToolsPerformancePolicy.Input(selection: .init(mode: .high),
            nativeEnergy: .init(autoplayVideo: true, autoplayGif: true, loopStickers: true, loopEmoji: true,
                fullTranslucency: true, extendBackgroundWork: false, autodownloadInBackground: false),
            environment: .init(isInForeground: true, lowPowerMode: false, batterySaving: false, thermal: .nominal),
            automaticFramesPerSecond: 60, maximumFramesPerSecond: 60)
        ToolsPerformancePolicyStore.shared.publish(enabled)
        addTeardownBlock { ToolsPerformancePolicyStore.shared.publish(previous ?? enabled) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pnp-dct-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = DCTAnimationCacheImpl(basePath: root.appendingPathComponent("cache").path,
            allocateTempFile: { root.appendingPathComponent(UUID().uuidString).path }, updateStorageStats: { _, _ in })
        let size = CGSize(width: 16, height: 16)
        let fetch: (AnimationCacheFetchOptions) -> Disposable = { options in
            options.writer.queue.async {
                for (index, duration) in durations.enumerated() {
                    options.writer.add(with: { surface in
                        let shade = UInt8(24 + index * 32)
                        for y in 0..<surface.height {
                            for x in 0..<surface.width {
                                let pixel = surface.argb.advanced(by: y * surface.bytesPerRow + x * 4)
                                pixel[0] = shade; pixel[1] = shade; pixel[2] = shade; pixel[3] = 255
                            }
                        }
                        return duration
                    }, proposedWidth: 16, proposedHeight: 16, insertKeyframe: index == 0)
                }
                options.writer.finish()
            }
            return EmptyDisposable
        }
        let loaded = expectation(description: "real DCT cache encoded")
        var referenceItem: AnimationCacheItem?
        let disposable = (cache.get(sourceId: "fixture", size: size, fetch: fetch) |> deliverOnMainQueue).start(next: { result in
            if let item = result.item { referenceItem = item; loaded.fulfill() }
        })
        defer { disposable.dispose() }
        wait(for: [loaded], timeout: 3)
        let reference = try XCTUnwrap(referenceItem)
        var samples: [Int] = []
        for _ in durations {
            let frame = try XCTUnwrap(reference.advance(advance: .frames(1), requestedFormat: .rgba))
            guard case let .rgba(bytes, width, height, stride) = frame.frame.format else { throw FixtureError.noPixels }
            samples.append(Int(bytes[(height / 2) * stride + (width / 2) * 4]))
        }
        XCTAssertEqual(Set(samples).count, durations.count, "Every real source frame must be visually distinguishable")
        let ready = expectation(description: "production renderer acquired its own DCT accessor")
        var notified = false
        let target = DCTTimingTarget()
        target.shouldBeAnimating = true
        let context = ItemAnimationContext(cache: cache, queueAffinity: 0, itemId: "fixture", size: size,
            useYuvA: false, fetch: { _ in XCTFail("Fixture cache must already exist"); return EmptyDisposable }, stateUpdated: {
                if !notified { notified = true; ready.fulfill() }
            })
        _ = context.targets.add(Weak(target))
        context.updateAddedTarget(target: target)
        wait(for: [ready], timeout: 3)
        XCTAssertTrue(context.isPlaying)
        let fixture = Fixture(context: context, target: target, reference: samples)
        fixture.tick(0)
        XCTAssertEqual(try fixture.index(), 0)
        return fixture
    }

    func testPNP02FifteenPlusEighteenMillisecondsAdvancesTwoRealFrames() throws {
        let fixture = try fixture()
        fixture.tick(0.015)
        XCTAssertEqual(try fixture.index(), 0)
        fixture.tick(1.0 / 30.0 - 0.015)
        XCTAssertEqual(try fixture.index(), 2)
        XCTAssertEqual(fixture.target.loopCount, 0)
    }

    func testPNP02JitteredThirtyAndSixtyHzFollowDecodedIndicesAndLoops() throws {
        for pair in [[0.015, 1.0 / 30.0 - 0.015], [0.031, 1.0 / 15.0 - 0.031]] {
            let fixture = try fixture()
            var elapsed = 0.0
            for _ in 0..<8 {
                for interval in pair {
                    elapsed += interval
                    fixture.tick(interval)
                    let frames = Int(floor((elapsed + 0.0000001) * 60.0))
                    XCTAssertEqual(try fixture.index(), frames % fixture.reference.count)
                    XCTAssertEqual(fixture.target.loopCount, frames / fixture.reference.count)
                }
            }
        }
    }

    func testPNP02ElapsedDuringDecodeAndQueuedCompletionIsConsumedOnce() throws {
        let fixture = try fixture()
        let pending = try XCTUnwrap(fixture.context.animationTick(advanceTimestamp: 1.0 / 60.0))
        XCTAssertNil(fixture.context.animationTick(advanceTimestamp: 0.015))
        let completion = pending.task()
        XCTAssertNil(fixture.context.animationTick(advanceTimestamp: 1.0 / 30.0 - 0.015))
        completion()
        XCTAssertEqual(try fixture.index(), 1)
        fixture.tick(0)
        XCTAssertEqual(try fixture.index(), 3)
        let deliveries = fixture.target.samples.count
        fixture.tick(0)
        XCTAssertEqual(fixture.target.samples.count, deliveries, "No repeated elapsed after drain")
    }

    func testPNP02VariableSourceDurationsAndCatchUpBoundsUseRealFrames() throws {
        let varying = try fixture(durations: [0.01, 0.03, 0.02, 0.025, 0.015])
        varying.tick(0.025)
        XCTAssertEqual(try varying.index(), 1)
        varying.tick(0.025)
        XCTAssertEqual(try varying.index(), 2)
        varying.tick(0.05)
        XCTAssertEqual(try varying.index(), 0)
        XCTAssertEqual(varying.target.loopCount, 1)
        let stalled = try fixture()
        stalled.tick(10)
        XCTAssertEqual(try stalled.index(), 15 % 7, "250 ms, not the ten-second stall")
        let tiny = try fixture(durations: Array(repeating: 0.000001, count: 7))
        tiny.tick(0.25)
        XCTAssertEqual(try tiny.index(), 64 % 7, "At most 64 actual loadNextFrame calls")
    }

    func testPNP02QueuedFrameCannotRepaintAnEnergyVetoedTarget() throws {
        let fixture = try fixture()
        let pending = try XCTUnwrap(fixture.context.animationTick(advanceTimestamp: 1.0 / 60.0))
        let completion = pending.task()
        let old = ToolsPerformancePolicyStore.shared.snapshot()?.input
        let native = ToolsPerformancePolicy.Energy(autoplayVideo: true, autoplayGif: true, loopStickers: true,
            loopEmoji: true, fullTranslucency: true, extendBackgroundWork: false, autodownloadInBackground: false)
        let high = ToolsPerformancePolicy.Input(selection: .init(mode: .high), nativeEnergy: native,
            environment: .init(isInForeground: true, lowPowerMode: false, batterySaving: false, thermal: .nominal),
            automaticFramesPerSecond: 60, maximumFramesPerSecond: 60)
        defer { ToolsPerformancePolicyStore.shared.publish(old ?? high) }
        var disabled = native
        disabled.loopEmoji = false
        ToolsPerformancePolicyStore.shared.publish(.init(selection: high.selection, nativeEnergy: disabled,
            environment: high.environment, automaticFramesPerSecond: 60, maximumFramesPerSecond: 60))
        let count = fixture.target.samples.count
        completion()
        XCTAssertEqual(fixture.target.samples.count, count)
        XCTAssertTrue(fixture.target.shouldBeAnimating, "The caller's request is retained")
    }

    private enum FixtureError: Error { case noPixels }
}
