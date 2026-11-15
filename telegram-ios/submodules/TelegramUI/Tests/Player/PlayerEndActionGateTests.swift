import Foundation
import XCTest
@testable import TelegramUI

/// CMC-14 exercises the production callback/generation/queue gate with plain
/// fake players. No Account, MediaPlayer, audio session/units or remote resource.
final class PlayerEndActionGateTests: XCTestCase {
    @MainActor func testQueuedEndAIsInertAfterManualNextInstallsB() {
        for stopAfterVoice in [false, true] {
            let owner = EndActionFixture()
            owner.stopAfterVoice = stopAfterVoice
            let a = EndActionFakePlayer(), b = EndActionFakePlayer()
            owner.install(a, isMusic: false)
            a.finishOnWorker()
            XCTAssertEqual(owner.main.count, 1)
            owner.beginNavigation()
            owner.install(b, isMusic: true)
            owner.main.drain()
            XCTAssertTrue(b.playing)
            XCTAssertTrue(b.effects.isEmpty)
            XCTAssertEqual(owner.nextCount, 0)
            XCTAssertEqual(owner.stopCount, 0)
            XCTAssertEqual(owner.policyReads, 0)
            XCTAssertTrue(owner.scheduledPlay)
        }
    }

    @MainActor func testWorkerRejectsAlreadyRetiredAWithoutEnqueuingOrReadingPolicy() {
        let owner = EndActionFixture()
        let a = EndActionFakePlayer(), b = EndActionFakePlayer()
        owner.install(a, isMusic: false)
        owner.beginNavigation()
        owner.install(b, isMusic: true)
        a.finishOnWorker()
        XCTAssertEqual(owner.main.count, 0)
        XCTAssertEqual(owner.policyReads, 0)
        XCTAssertTrue(b.effects.isEmpty)
    }

    @MainActor func testNextRetiresAWhileReplacementIsStillLoading() {
        let owner = EndActionFixture()
        owner.stopAfterVoice = true
        let a = EndActionFakePlayer()
        owner.install(a, isMusic: false)
        a.finishOnWorker()
        owner.beginNavigation() // No replacement item has been delivered yet.
        owner.main.drain()
        XCTAssertTrue(a.effects.isEmpty)
        XCTAssertEqual(owner.policyReads, 0)
        XCTAssertEqual(owner.stopCount, 0)
        XCTAssertEqual(owner.nextCount, 0)
        XCTAssertTrue(owner.scheduledPlay)
    }

    @MainActor func testSameNativeObjectAfterRearmOrABARejectsOldGeneration() {
        let owner = EndActionFixture()
        let a = EndActionFakePlayer(), b = EndActionFakePlayer()
        owner.install(a, isMusic: false)
        a.finishOnWorker()
        owner.install(b, isMusic: false)
        owner.install(a, isMusic: false)
        owner.main.drain()
        XCTAssertTrue(a.effects.isEmpty)
        XCTAssertEqual(owner.nextCount, 0)
        XCTAssertEqual(owner.policyReads, 0)
        a.finishOnWorker() // The newly registered A callback is still live.
        owner.main.drain()
        XCTAssertEqual(owner.nextCount, 1)
    }

    @MainActor func testLiveEndPreservesLoopStopAndAdvancePolicy() {
        for item in [(true, false, true), (false, false, true), (false, false, false), (false, true, true)] {
            let owner = EndActionFixture()
            owner.loopCurrentItem = item.0
            owner.stopAfterVoice = item.2
            let player = EndActionFakePlayer()
            owner.install(player, isMusic: item.1)
            player.finishOnWorker()
            XCTAssertTrue(player.effects.isEmpty) // No effects on the worker.
            owner.main.drain()
            if item.0 {
                XCTAssertEqual(player.effects, ["seek:0", "play"])
                XCTAssertEqual(owner.stopCount, 0)
                XCTAssertEqual(owner.nextCount, 0)
                player.finishOnWorker()
                owner.main.drain()
                XCTAssertEqual(player.effects, ["seek:0", "play", "seek:0", "play"])
            } else if !item.1 && item.2 {
                XCTAssertEqual(player.effects, ["pause"])
                XCTAssertFalse(player.playing)
                XCTAssertFalse(owner.scheduledPlay)
                XCTAssertEqual(owner.stopCount, 1)
                player.playing = true // Native overlay replay can bypass playlist control.
                player.finishOnWorker()
                owner.main.drain()
                XCTAssertEqual(player.effects, ["pause", "pause"])
                XCTAssertEqual(owner.stopCount, 2)
            } else {
                XCTAssertTrue(player.effects.isEmpty)
                XCTAssertEqual(owner.nextCount, 1)
                XCTAssertTrue(owner.scheduledPlay)
            }
        }
    }

    @MainActor func testAdvanceConsumesRegistrationBeforeDuplicateQueuedEffects() {
        let owner = EndActionFixture()
        let player = EndActionFakePlayer()
        owner.install(player, isMusic: false)
        player.finishOnWorker()
        player.finishOnWorker()
        XCTAssertEqual(owner.main.count, 2)
        owner.main.drain()
        XCTAssertEqual(owner.policyReads, 1)
        XCTAssertEqual(owner.stopCount, 0)
        XCTAssertEqual(owner.nextCount, 1)
        player.finishOnWorker()
        XCTAssertEqual(owner.main.count, 0)
    }

    @MainActor func testReplacementDuringLoopSeekCannotPlayAOrB() {
        let owner = EndActionFixture()
        owner.loopCurrentItem = true
        let a = EndActionFakePlayer(), b = EndActionFakePlayer()
        owner.install(a, isMusic: false)
        owner.onSeek = { [weak owner] in owner?.install(b, isMusic: true) }
        a.finishOnWorker()
        owner.main.drain()
        XCTAssertEqual(a.effects, ["seek:0"])
        XCTAssertTrue(b.effects.isEmpty)
        XCTAssertTrue(b.playing)
    }

    @MainActor func testReplacementDuringPolicyReadPrecedesEveryEffect() {
        for mode in [(true, false), (false, true), (false, false)] {
            let owner = EndActionFixture()
            owner.loopCurrentItem = mode.0
            owner.stopAfterVoice = mode.1
            let a = EndActionFakePlayer(), b = EndActionFakePlayer()
            owner.install(a, isMusic: false)
            owner.onPolicyRead = { [weak owner] in owner?.install(b, isMusic: true) }
            a.finishOnWorker()
            owner.main.drain()
            XCTAssertTrue(a.effects.isEmpty)
            XCTAssertTrue(b.effects.isEmpty)
            XCTAssertEqual(owner.nextCount, 0)
            XCTAssertEqual(owner.stopCount, 0)
        }
    }
}

private final class EndActionFakePlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var end: (() -> Void)?
    private let worker = DispatchQueue(label: "PlayerEndActionFixture.Worker")
    var effects: [String] = [] // Owner-queue-only, never read/written by finishOnWorker.
    var playing = true

    func setEnd(_ callback: @escaping () -> Void) { lock.lock(); end = callback; lock.unlock() }
    func finishOnWorker() {
        let done = DispatchSemaphore(value: 0)
        worker.async {
            self.lock.lock()
            let callback = self.end
            self.lock.unlock()
            callback?()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success, "Fixture worker exceeded one second")
    }
}

private final class EndActionControlledMain: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return tasks.count }
    func enqueue(_ task: @escaping () -> Void) { lock.lock(); tasks.append(task); lock.unlock() }
    @MainActor func drain() {
        for _ in 0..<8 {
            lock.lock()
            let task = tasks.isEmpty ? nil : tasks.removeFirst()
            lock.unlock()
            guard let task else { return }
            task()
        }
        XCTAssertEqual(count, 0, "Fixture exceeded its eight-step main-queue bound")
    }
}

private final class EndActionFixture {
    let gate = ExteralessPlayerEndActionGate()
    let main = EndActionControlledMain()
    private(set) var current: EndActionFakePlayer?
    var loopCurrentItem = false
    var stopAfterVoice = false
    var scheduledPlay = false
    var nextCount = 0
    var stopCount = 0
    var policyReads = 0
    var onSeek: (() -> Void)?
    var onPolicyRead: (() -> Void)?

    func beginNavigation() { gate.invalidate(); scheduledPlay = true }

    func install(_ player: EndActionFakePlayer, isMusic: Bool) {
        gate.invalidate()
        current = player
        let identity = ObjectIdentifier(player)
        player.setEnd(gate.callback(identity: identity, enqueue: { [main] action in main.enqueue(action) }, mode: { [weak self] in
            guard let self, let current = self.current, ObjectIdentifier(current) == identity else { return nil }
            XCTAssertTrue(Thread.isMainThread)
            self.policyReads += 1
            self.onPolicyRead?()
            return ExteralessPlayerEndActionGate.mode(loopCurrentItem: self.loopCurrentItem, isMusic: isMusic, stopAfterVoice: self.stopAfterVoice)
        }, seekToStart: { [weak self] in
            guard let self, let current = self.current, ObjectIdentifier(current) == identity else { return }
            XCTAssertTrue(Thread.isMainThread)
            current.effects.append("seek:0")
            self.onSeek?()
        }, play: { [weak self] in
            guard let current = self?.current, ObjectIdentifier(current) == identity else { return }
            XCTAssertTrue(Thread.isMainThread)
            current.effects.append("play")
            current.playing = true
        }, stop: { [weak self] in
            guard let self, let current = self.current, ObjectIdentifier(current) == identity else { return }
            XCTAssertTrue(Thread.isMainThread)
            self.scheduledPlay = false
            self.stopCount += 1
            current.effects.append("pause")
            current.playing = false
        }, advance: { [weak self] in
            guard let self, let current = self.current, ObjectIdentifier(current) == identity else { return }
            XCTAssertTrue(Thread.isMainThread)
            self.scheduledPlay = true
            self.nextCount += 1
        }))
    }
}
