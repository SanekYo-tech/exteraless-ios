import Foundation

/// Original 1200 ms debounce, driven by actual changes and foreground events.
/// There is no repeating timer, retry loop, background task or account lookup.
@MainActor public final class CloudAutoSync {
    private let settings: ClientSettings
    private let session: CloudSyncSession
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var observation: ClientSettingsObservation?
    private var delayTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var scheduleId = UUID()
    private var syncId = UUID()
    private var foreground = false
    private var dirty = false
    private var waitingForIdle = false
    private var closed = false
    private var lastPolicy: CloudSyncPolicy

    public init(settings: ClientSettings, session: CloudSyncSession,
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.settings = settings
        self.session = session
        self.sleep = sleep
        self.lastPolicy = CloudSyncPolicy(snapshot: settings.readSnapshot())
        observation = settings.observe { [weak self] keys in
            Task { @MainActor [weak self] in self?.settingsChanged(keys) }
        }
        // Re-query after observing so a concurrent writer cannot be missed.
        self.lastPolicy = CloudSyncPolicy(snapshot: settings.readSnapshot())
    }

    deinit { observation?.cancel(); delayTask?.cancel(); syncTask?.cancel() }

    public func setForeground(_ foreground: Bool) {
        guard !closed, self.foreground != foreground else { return }
        self.foreground = foreground
        if foreground { dirty = true; schedule() }
        else { cancelScheduled(cancelRunning: true) }
    }

    /// Call from the session's didChange fan-out. A debounce that found an active
    /// manual operation waits for this event rather than polling it.
    public func sessionDidChange() {
        guard !session.isBusy, waitingForIdle else { return }
        waitingForIdle = false
        schedule()
    }

    public func clear() {
        closed = true
        observation?.cancel()
        observation = nil
        cancelScheduled(cancelRunning: true)
    }

    private func settingsChanged(_ keys: Set<String>) {
        guard !closed else { return }
        let snapshot = settings.readSnapshot()
        let policy = CloudSyncPolicy(snapshot: snapshot)
        if policy.includeApiKeys != lastPolicy.includeApiKeys {
            // Cancel even a manual upload before another chunk can contain a key
            // excluded by the new policy. An already-sent chunk cannot be unsent.
            session.cancel()
        }
        lastPolicy = policy
        guard policy.autoSync else { cancelScheduled(cancelRunning: true); return }
        let admitted = (try? CloudCredentials.admittedIDs(publicValues: snapshot.values)) ?? []
        let credentialKeys = policy.includeApiKeys ? Set(admitted.map(\.settingKey)) : []
        let portableKeys = Set(snapshot.definitions.filter(CloudArchivePolicy.isPortable).map(\.key))
        guard keys.isEmpty || !keys.isDisjoint(with: portableKeys.union(credentialKeys).union(["cloud.autoSync", "cloud.includeApiKeys"])) else { return }
        dirty = true
        schedule()
    }

    private func schedule() {
        guard !closed, foreground, dirty, CloudSyncPolicy(snapshot: settings.readSnapshot()).autoSync else { return }
        delayTask?.cancel()
        let id = UUID()
        scheduleId = id
        let sleep = self.sleep
        delayTask = Task { @MainActor [weak self] in
            do { try await sleep(1_200_000_000) } catch { return }
            guard let self, !self.closed, self.foreground, self.scheduleId == id, !Task.isCancelled else { return }
            self.delayTask = nil
            if self.session.isBusy { self.waitingForIdle = true; return }
            self.dirty = false
            let syncId = UUID()
            self.syncId = syncId
            self.syncTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { _ = try await self.session.syncNow() } catch { /* Session publishes a bounded, typed error. */ }
                guard self.syncId == syncId else { return }
                self.syncTask = nil
                // Only a NEW observed edit justifies another run; a network error
                // by itself never re-arms the scheduler.
                if self.dirty { self.schedule() }
            }
        }
    }

    private func cancelScheduled(cancelRunning: Bool) {
        scheduleId = UUID()
        delayTask?.cancel()
        delayTask = nil
        waitingForIdle = false
        if cancelRunning, syncTask != nil {
            syncId = UUID()
            syncTask?.cancel()
            syncTask = nil
            session.cancel()
        }
    }
}
