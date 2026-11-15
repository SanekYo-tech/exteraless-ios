import Foundation

/// Action-at-end may arrive on a decoder worker and wait on the main queue.
/// Only the lock-protected identity/generation is read on the worker; policy and
/// effects run on the supplied owner queue after a second admission check.
final class ExteralessPlayerEndActionGate: @unchecked Sendable {
    enum Mode { case loopItem, stop, advance }

    private struct Token: Equatable {
        let identity: ObjectIdentifier
        let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var current: Token?

    func invalidate() {
        lock.lock()
        generation &+= 1
        current = nil
        lock.unlock()
    }

    func callback(identity: ObjectIdentifier, enqueue: @escaping (@escaping () -> Void) -> Void,
                  mode: @escaping () -> Mode?, seekToStart: @escaping () -> Void,
                  play: @escaping () -> Void, stop: @escaping () -> Void,
                  advance: @escaping () -> Void) -> () -> Void {
        lock.lock()
        generation &+= 1
        let token = Token(identity: identity, generation: generation)
        current = token
        lock.unlock()
        return { [weak self] in
            // Decoder/worker boundary: do not touch the player's main-only state.
            guard let self, self.matches(token) else { return }
            enqueue { [weak self] in
                // The item may have changed while this block waited on main.
                guard let self, self.matches(token), let mode = mode() else { return }
                switch mode {
                case .loopItem:
                    guard self.matches(token) else { return }
                    seekToStart()
                    // A seek can synchronously cause owner/item replacement.
                    guard self.matches(token) else { return }
                    play()
                case .stop:
                    // Native overlays can replay the same item directly, without
                    // rebuilding the playlist. Keep its registration usable.
                    guard self.matches(token) else { return }
                    stop()
                case .advance:
                    guard self.consume(token) else { return }
                    advance()
                }
            }
        }
    }

    static func mode(loopCurrentItem: Bool, isMusic: Bool, stopAfterVoice: Bool) -> Mode {
        if loopCurrentItem { return .loopItem }
        return !isMusic && stopAfterVoice ? .stop : .advance
    }

    private func matches(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == token
    }

    /// Advancing retires the callback before the first effect. A second queued
    /// completion cannot advance the same still-loading playlist again.
    private func consume(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == token else { return false }
        generation &+= 1
        current = nil
        return true
    }
}
