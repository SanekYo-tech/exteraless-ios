import ExteralessCore
import Foundation

/// A live per-target veto. Keeps the caller's visibility/loop request separate from
/// native permissions, so resuming a shared clock cannot re-enable an opted-out kind.
public final class ToolsPerformanceAnimationGate: @unchecked Sendable {
    private var kind = ToolsPerformancePolicy.AnimationKind.emoji
    private let updated: @MainActor () -> Void
    private var observer: NSObjectProtocol?
    public private(set) var allowsAnimation: Bool
    public private(set) var allowsEffects: Bool

    public init(kind: ToolsPerformancePolicy.AnimationKind = .emoji, updated: @escaping @MainActor () -> Void) {
        precondition(Thread.isMainThread)
        self.kind = kind
        self.updated = updated
        let budget = ToolsPerformancePolicyStore.shared.snapshot()?.budget
        self.allowsAnimation = budget?.allowsAnimation(kind) ?? true
        self.allowsEffects = budget?.allowsAnimation(.effect) ?? true
        observer = NotificationCenter.default.addObserver(forName: ToolsPerformancePolicyStore.didChange,
            object: ToolsPerformancePolicyStore.shared, queue: .main) { [weak self] _ in self?.refresh() }
    }

    public func update(kind: ToolsPerformancePolicy.AnimationKind) {
        precondition(Thread.isMainThread)
        self.kind = kind
        refresh()
    }

    private func refresh() {
        precondition(Thread.isMainThread)
        let budget = ToolsPerformancePolicyStore.shared.snapshot()?.budget
        let allowed = budget?.allowsAnimation(kind) ?? true
        let effects = budget?.allowsAnimation(.effect) ?? true
        guard allowed != allowsAnimation || effects != allowsEffects else { return }
        allowsAnimation = allowed; allowsEffects = effects
        MainActor.assumeIsolated { updated() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Main-run-loop clock shared by the DCT and Subcodec *client* renderers. First
/// frame/cache APIs do not depend on this clock. Frame delta remains in seconds
/// when the budget changes, rather than slowing a 60-fps animation by half.
public final class ToolsPerformanceRenderClock: @unchecked Sendable {
    private let automaticFPS = ProcessInfo.processInfo.processorCount > 2 ? 60 : 30
    private let tick: (Double) -> Void
    private var observer: NSObjectProtocol?
    private var timer: Foundation.Timer?
    private var hasPlayingTargets = false
    private var requestedFPS = 0
    private var installedFPS = 0
    private var previousTimestamp: TimeInterval?
    private var cursor = ToolsPerformancePublicationCursor()

    /// Creation, setPlaying and timer/notification delivery are main-thread only.
    public init(tick: @escaping (Double) -> Void) {
        precondition(Thread.isMainThread)
        self.tick = tick
        observer = NotificationCenter.default.addObserver(forName: ToolsPerformancePolicyStore.didChange,
            object: ToolsPerformancePolicyStore.shared, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func setPlaying(_ value: Bool) {
        precondition(Thread.isMainThread)
        hasPlayingTargets = value
        refresh()
    }

    private func refresh() {
        precondition(Thread.isMainThread)
        if let publication = ToolsPerformancePolicyStore.shared.snapshot() {
            if let budget = cursor.accept(publication) { requestedFPS = budget.animationFramesPerSecond }
        } else {
            // Unconfigured extension/early bootstrap retains the native heuristic.
            requestedFPS = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(30, automaticFPS) : automaticFPS
        }
        let fps = hasPlayingTargets ? requestedFPS : 0
        guard installedFPS != fps else { return }
        timer?.invalidate(); timer = nil
        installedFPS = fps
        previousTimestamp = nil
        guard fps > 0 else { return }
        previousTimestamp = ProcessInfo.processInfo.systemUptime
        let timer = Foundation.Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in self?.fire() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fire() {
        precondition(Thread.isMainThread)
        guard hasPlayingTargets, installedFPS > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTimestamp.map { now - $0 } ?? (1.0 / Double(installedFPS))
        previousTimestamp = now
        // No catch-up burst after backgrounding or a long main-run-loop stall.
        tick(max(0, min(0.25, elapsed)))
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
