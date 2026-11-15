import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsPerformancePolicyTests: XCTestCase {
    private typealias Policy = ToolsPerformancePolicy
    private var enabled: Policy.Energy {
        .init(autoplayVideo: true, autoplayGif: true, loopStickers: true, loopEmoji: true,
              fullTranslucency: true, extendBackgroundWork: true, autodownloadInBackground: true)
    }
    private var foreground: Policy.Environment {
        .init(isInForeground: true, lowPowerMode: false, batterySaving: false, thermal: .nominal)
    }
    private func input(_ mode: Policy.Mode, energy: Policy.Energy? = nil, environment: Policy.Environment? = nil,
                       automaticFPS: Int = 30, maximumFPS: Int = 60, stored: Bool = true) -> Policy.Input {
        .init(selection: .init(mode: mode, isStoredOverride: stored), nativeEnergy: energy ?? enabled,
              environment: environment ?? foreground, automaticFramesPerSecond: automaticFPS, maximumFramesPerSecond: maximumFPS)
    }

    func testEveryOriginalValueHasADefinedNativeRung() throws {
        let automatic = Policy.resolve(input(.automatic))
        let high = Policy.resolve(input(.high))
        let average = Policy.resolve(input(.average))
        let low = Policy.resolve(input(.low))
        XCTAssertEqual(automatic.animationFramesPerSecond, 30)
        XCTAssertEqual(automatic.energy, enabled)
        XCTAssertEqual(high.animationFramesPerSecond, 60, "Manual budget, not a fabricated processor count")
        XCTAssertEqual(high.energy, enabled)
        XCTAssertEqual(average.animationFramesPerSecond, 30)
        XCTAssertTrue(average.energy.autoplayVideo && average.energy.autoplayGif && average.energy.loopEmoji && average.energy.loopStickers)
        XCTAssertFalse(average.energy.fullTranslucency || average.energy.extendBackgroundWork || average.energy.autodownloadInBackground)
        XCTAssertEqual(low.animationFramesPerSecond, 0)
        assertVisualWorkStopped(low.energy)
        XCTAssertFalse(low.energy.extendBackgroundWork || low.energy.autodownloadInBackground)
        XCTAssertEqual(Policy.definition.defaultValue, .integer(0))
        for mode in Policy.Mode.allCases { try Policy.definition.validate(.integer(mode.rawValue)) }
        XCTAssertThrowsError(try Policy.definition.validate(.integer(4)))
        XCTAssertThrowsError(try Policy.definition.validate(.bool(true)))
    }

    func testEveryExplicitNativeFalseRemainsFalseInEveryMode() {
        let fields: [WritableKeyPath<Policy.Energy, Bool>] = [\.autoplayVideo, \.autoplayGif, \.loopStickers, \.loopEmoji,
            \.fullTranslucency, \.extendBackgroundWork, \.autodownloadInBackground]
        for mode in Policy.Mode.allCases {
            for field in fields {
                var native = enabled
                native[keyPath: field] = false
                let request = input(mode, energy: native)
                XCTAssertFalse(Policy.resolve(request).energy[keyPath: field])
                XCTAssertEqual(request.nativeEnergy, native, "No profile mutates the user's native settings")
            }
        }
    }

    func testAutomaticPreservesNativeHardwareHeuristicAndHighKeepsActualRendererCeiling() {
        var native = enabled
        native.loopEmoji = false; native.fullTranslucency = false
        XCTAssertEqual(Policy.resolve(input(.automatic, energy: native)).energy, native)
        XCTAssertEqual(Policy.resolve(input(.high, energy: native)).energy, native)
        XCTAssertEqual(Policy.resolve(input(.automatic, automaticFPS: 60)).animationFramesPerSecond, 60)
        for mode in Policy.Mode.allCases {
            XCTAssertLessThanOrEqual(Policy.resolve(input(mode, automaticFPS: 60, maximumFPS: 24)).animationFramesPerSecond, 24)
            XCTAssertEqual(Policy.resolve(input(mode, maximumFPS: 0)).animationFramesPerSecond, 0)
        }
    }

    func testHighCannotResumeAnOptedOutEmojiThroughAnEnabledStickerClock() {
        var native = enabled
        native.loopEmoji = false
        let high = Policy.resolve(input(.high, energy: native))
        XCTAssertEqual(high.animationFramesPerSecond, 60)
        XCTAssertFalse(high.allowsAnimation(.emoji))
        XCTAssertTrue(high.allowsAnimation(.sticker))
        native = enabled; native.loopStickers = false
        let stickerOptOut = Policy.resolve(input(.high, energy: native))
        XCTAssertTrue(stickerOptOut.allowsAnimation(.emoji))
        XCTAssertFalse(stickerOptOut.allowsAnimation(.sticker))
        XCTAssertFalse(Policy.resolve(input(.average)).allowsAnimation(.effect))
        let low = Policy.resolve(input(.low))
        XCTAssertFalse(low.allowsAnimation(.emoji) || low.allowsAnimation(.sticker) || low.allowsAnimation(.effect))
    }

    func testLowPowerAndNativeBatteryThresholdAlwaysWinOverHigh() {
        for mode in Policy.Mode.allCases {
            for systemSaver in [true, false] {
                var environment = foreground
                environment.lowPowerMode = systemSaver
                environment.batterySaving = !systemSaver
                let budget = Policy.resolve(input(mode, environment: environment))
                XCTAssertEqual(budget.animationFramesPerSecond, 0)
                assertVisualWorkStopped(budget.energy)
                XCTAssertFalse(budget.energy.extendBackgroundWork || budget.energy.autodownloadInBackground)
            }
        }
    }

    func testThermalRestrictionsNeverGrantWorkAndClearOnCurrentEnvironment() {
        var environment = foreground
        environment.thermal = .fair
        let fair = Policy.resolve(input(.high, environment: environment))
        XCTAssertEqual(fair.animationFramesPerSecond, 30)
        XCTAssertFalse(fair.energy.fullTranslucency)
        for thermal in [Policy.Thermal.serious, .critical, .unknown] {
            environment.thermal = thermal
            let budget = Policy.resolve(input(.high, environment: environment))
            XCTAssertEqual(budget.animationFramesPerSecond, 0)
            assertVisualWorkStopped(budget.energy)
            XCTAssertFalse(budget.energy.extendBackgroundWork || budget.energy.autodownloadInBackground)
        }
        XCTAssertEqual(Policy.resolve(input(.high)).animationFramesPerSecond, 60)
    }

    func testBackgroundAndAccessibilityPauseVisualWorkWithoutEnablingNativeBackgroundPermission() {
        var environment = foreground
        environment.isInForeground = false
        var native = enabled
        native.extendBackgroundWork = false; native.autodownloadInBackground = false
        let background = Policy.resolve(input(.high, energy: native, environment: environment))
        XCTAssertEqual(background.animationFramesPerSecond, 0)
        assertVisualWorkStopped(background.energy)
        XCTAssertFalse(background.energy.extendBackgroundWork || background.energy.autodownloadInBackground)
        environment = foreground; environment.reduceMotion = true
        XCTAssertEqual(Policy.resolve(input(.high, environment: environment)).animationFramesPerSecond, 0)
        environment = foreground; environment.reduceTransparency = true
        XCTAssertFalse(Policy.resolve(input(.high, environment: environment)).energy.fullTranslucency)
        XCTAssertEqual(Policy.resolve(input(.high, energy: native)).energy, native)
    }

    func testActualStoreResetPublishesAutomaticAndPreservesOverrideAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-performance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("client.json"), secretStore: NoSecrets())
        try settings.register([Policy.definition])
        let publications = ToolsPerformancePolicyStore(notifications: NotificationCenter())
        func publish() -> ToolsPerformancePublication {
            publications.publish(.init(selection: .init(snapshot: settings.readSnapshot()), nativeEnergy: enabled,
                environment: foreground, automaticFramesPerSecond: 30, maximumFramesPerSecond: 60))
        }
        let absent = publish()
        XCTAssertFalse(absent.input.selection.isStoredOverride)
        try settings.applyPublic([Policy.key: .integer(3)])
        XCTAssertEqual(publish().budget.animationFramesPerSecond, 0)
        try settings.applyPublic([Policy.key: .integer(0)])
        let explicitAutomatic = publish()
        XCTAssertTrue(explicitAutomatic.input.selection.isStoredOverride)
        try settings.applyPublic([:], resetting: [Policy.key])
        let reset = publish()
        XCTAssertEqual(reset.input.selection.mode, .automatic)
        XCTAssertFalse(reset.input.selection.isStoredOverride)
        XCTAssertEqual(reset.budget, absent.budget)
        XCTAssertGreaterThan(reset.revision, explicitAutomatic.revision)
        XCTAssertFalse(settings.readSnapshot().storedKeys.contains(Policy.key))
    }

    func testPublicationIsCommittedBeforeNotificationAndSuppressesRepeatedInputs() {
        let center = NotificationCenter(), observed = Revisions()
        let store = ToolsPerformancePolicyStore(notifications: center)
        let token = center.addObserver(forName: ToolsPerformancePolicyStore.didChange, object: store, queue: nil) { _ in
            if let publication = store.snapshot() { observed.append(publication.revision) }
        }
        defer { center.removeObserver(token) }
        XCTAssertNil(store.snapshot())
        let first = store.publish(input(.high))
        XCTAssertEqual(store.publish(input(.high)), first)
        let second = store.publish(input(.average))
        var environment = foreground; environment.isInForeground = false
        let third = store.publish(input(.average, environment: environment))
        XCTAssertEqual(observed.values(), [first.revision, second.revision, third.revision])
        XCTAssertEqual(third.revision, first.revision + 2)
        XCTAssertEqual(store.snapshot()?.budget.animationFramesPerSecond, 0)
    }

    func testLatePublicationCannotResumeAStoppedRenderer() {
        let store = ToolsPerformancePolicyStore(notifications: NotificationCenter())
        let high = store.publish(input(.high))
        let low = store.publish(input(.low))
        var cursor = ToolsPerformancePublicationCursor()
        XCTAssertEqual(cursor.accept(low)?.animationFramesPerSecond, 0)
        XCTAssertNil(cursor.accept(high))
        XCTAssertNil(cursor.accept(low))
        let resumed = store.publish(input(.automatic))
        XCTAssertEqual(cursor.accept(resumed)?.animationFramesPerSecond, 30)
    }

    func testAverageClockPreservesSixtyFPSTimeAndSkippedLoopBoundary() {
        let durations = Array(repeating: 1.0 / 60.0, count: 51)
        for fps in [30, 60] {
            var index = 0, advanced = 0, loops = 0
            var remaining = durations[0]
            for _ in 0..<fps {
                let step = Policy.advanceFrames(frameCount: 51, frameIndex: index, remainingDuration: remaining,
                    durations: durations, elapsed: 1.0 / Double(fps))
                index = step.index; remaining = step.remainingDuration; advanced += step.frames
                if step.didLoop { loops += 1 }
            }
            XCTAssertEqual(advanced, 60)
            XCTAssertEqual(index, 9)
            XCTAssertEqual(loops, 1, "A skipped-over loop boundary still reports one loop")
            XCTAssertEqual(remaining, durations[0], accuracy: 0.000001)
        }
    }

    func testFrameAdvancementIsBoundedForBadMetadataAndDoesNotCatchUpBackgroundTime() {
        let step = Policy.advanceFrames(frameCount: 3, frameIndex: 0, remainingDuration: .nan,
            durations: [0, .infinity, 0.00000001], elapsed: 3_600)
        XCTAssertLessThanOrEqual(step.frames, 64)
        XCTAssertTrue((0..<3).contains(step.index))
        XCTAssertTrue(step.remainingDuration.isFinite && step.remainingDuration > 0)
        XCTAssertEqual(Policy.advanceFrames(frameCount: 0, frameIndex: 0, remainingDuration: 0,
            durations: [], elapsed: 1).frames, 0)
        XCTAssertEqual(Policy.advanceFrames(frameCount: 2, frameIndex: 0, remainingDuration: 1,
            durations: [1, 1], elapsed: .nan).frames, 0)
    }

    private func assertVisualWorkStopped(_ energy: Policy.Energy, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(energy.autoplayVideo || energy.autoplayGif || energy.loopStickers || energy.loopEmoji || energy.fullTranslucency, file: file, line: line)
    }
    private struct NoSecrets: ClientSecretStore {
        func data(for key: String) throws -> Data? { XCTFail("No secret reads for a performance profile"); return nil }
        func set(_ data: Data?, for key: String) throws { XCTFail("No secret writes for a performance profile") }
    }
    private final class Revisions: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UInt64] = []
        func append(_ value: UInt64) { lock.lock(); items.append(value); lock.unlock() }
        func values() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
