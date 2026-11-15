import AccountContext
import CoreLocation
import ExteralessCore
import Foundation
import PhoneNumberFormat
import SwiftSignalKit
import TelegramCore
import UIKit
import Weather

private final class ExteralessPillSignalHolder: @unchecked Sendable {
    let disposable = MetaDisposable()
    deinit { self.disposable.dispose() }
}

@MainActor final class ExteralessPillRuntime {
    private final class WeakSubscription {
        weak var value: ExteralessPillSubscription?
        init(_ value: ExteralessPillSubscription) { self.value = value }
    }
    private final class WeakScreen {
        weak var value: ExteralessChatTableController?
        init(_ value: ExteralessChatTableController) { self.value = value }
    }
    let context: AccountContext
    let lease: PillAccountLease
    let store = PillSettingsStore(settings: .shared)
    let http: PillHTTPClient
    let rates: PillRateProvider
    private var subscriptions: [WeakSubscription] = []
    private var screens: [WeakScreen] = []
    private var lastBotRequest: Date?
    private(set) var botRequests = 0
    private(set) var botResponses = 0
    private(set) var migrationError: String?
    private let settingsQueue = DispatchQueue(label: "Exteraless.Pills.Settings", qos: .utility)

    lazy var weather: PillWeatherProvider = {
        PillWeatherProvider(lease: self.lease, http: self.http, nativeFetch: { [weak self] coordinate, completion in
            let token = PillCancellation()
            let holder = ExteralessPillSignalHolder()
            token.add { holder.disposable.dispose() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lease.isValid, !token.isCancelled else { return }
                let now = Date()
                if let last = self.lastBotRequest, now.timeIntervalSince(last) < 5 {
                    completion(.failure(.throttled(retryAt: last.addingTimeInterval(5)))); return
                }
                self.lastBotRequest = now; self.botRequests += 1
                holder.disposable.set((requestWeatherData(context: self.context, location: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                |> filter { $0 != nil } // resolvePeerByName can first emit a progress/nil result.
                |> timeout(15, queue: .mainQueue(), alternate: .single(nil))
                |> take(1)
                |> deliverOnMainQueue).start(next: { [weak self] value in
                    guard let self, self.lease.isValid, !token.isCancelled else { return }
                    guard let value else { completion(.failure(.timeout)); return }
                    do {
                        let reading = try PillWeatherReading(coordinate: coordinate, celsius: value.temperature, emoji: value.emoji, updatedAt: Date(), source: .telegram)
                        self.botResponses += 1
                        completion(.success(reading))
                    } catch { completion(.failure(.invalidData)) }
                }, completed: {
                    // The request pool admits only the first terminal result.
                    if !token.isCancelled { completion(.failure(.unavailable)) }
                }))
            }
            return token
        })
    }()

    init(context: AccountContext) {
        self.context = context
        let lease = PillAccountLease(scope: PillAccountScope(accountId: context.account.id.int64))
        self.lease = lease
        let http = PillHTTPClient(transport: PillURLSessionTransport())
        self.http = http
        self.rates = PillRateProvider(lease: lease, settings: .shared, http: http)
        let store = self.store
        self.settingsQueue.async { [weak self] in
            let error: String?
            do { try lease.withCurrent { try store.migrateLegacyRates() }; error = nil }
            catch PillError.cancelled { return }
            catch { error = "The previous rate layout could not be migrated. Its saved configuration was preserved." }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lease.isValid else { return }
                self.migrationError = error
                for reference in self.screens {
                    if let screen = reference.value as? ExteralessPillTableController, screen.screenIsVisible { screen.settingsChanged?() }
                }
            }
        }
    }
    func configuration() throws -> PillConfiguration { try PillConfiguration(values: ClientSettings.shared.snapshot()) }
    func descriptors() throws -> [PillDescriptor] {
        PillRegistry.descriptors(configuration: try self.configuration(), plugins: PillPluginRegistry.shared.descriptors)
    }
    func subscribe(_ descriptor: PillDescriptor, update: @escaping (PillModel) -> Void) -> ExteralessPillSubscription {
        let subscription = ExteralessPillSubscription(runtime: self, descriptor: descriptor, update: update)
        self.subscriptions.removeAll { $0.value == nil }
        self.subscriptions.append(WeakSubscription(subscription))
        subscription.start()
        return subscription
    }
    func trackScreen(_ screen: ExteralessChatTableController) {
        self.screens.removeAll { $0.value == nil }
        self.screens.append(WeakScreen(screen))
    }
    func invalidate() {
        guard self.lease.isValid else { return }
        self.lease.invalidate()
        self.rates.cancel(); self.weather.cancel()
        for reference in self.subscriptions { reference.value?.invalidate() }
        self.subscriptions.removeAll()
        for reference in self.screens { reference.value?.invalidateAccount() }
        self.screens.removeAll()
    }
    func toggleGhost(completion: @escaping (String?) -> Void) {
        let lease = self.lease
        self.settingsQueue.async {
            let error: String?
            do {
                try lease.withCurrent {
                    _ = try PrivacyGhostModeMutation.toggle(in: .shared)
                }
                error = nil
            } catch PillError.cancelled { return }
            catch { error = "Couldn't save ghost mode. Check the current privacy settings." }
            DispatchQueue.main.async { if lease.isValid { completion(error) } }
        }
    }
}

/// Existing feed factories and the new chat-list factory share the same account-generation providers.
@MainActor enum ExteralessPillRuntimes {
    private final class Reference {
        weak var value: ExteralessPillRuntime?
        init(_ value: ExteralessPillRuntime) { self.value = value }
    }
    private static var values: [ObjectIdentifier: Reference] = [:]
    static func get(context: AccountContext) -> ExteralessPillRuntime {
        self.values = self.values.filter { $0.value.value != nil }
        let key = ObjectIdentifier(context)
        if let value = self.values[key]?.value, value.lease.isValid { return value }
        let value = ExteralessPillRuntime(context: context)
        self.values[key] = Reference(value)
        return value
    }
    static func clear() {
        for reference in self.values.values { reference.value?.invalidate() }
        self.values.removeAll()
    }
}

@MainActor final class ExteralessPillSubscription {
    private let runtime: ExteralessPillRuntime
    let descriptor: PillDescriptor
    private let update: (PillModel) -> Void
    private let native = MetaDisposable()
    private let secondary = MetaDisposable()
    private var remote: PillCancellation?
    private var settingsObservation: ClientSettingsObservation?
    private var timer: Foundation.Timer?
    private var retryTimer: Foundation.Timer?
    private var notifications: [NSObjectProtocol] = []
    private var location: ExteralessPillLocation?
    private var active = false
    private var cancelled = false
    private var job = UUID()
    private var previousCPU: PillCPUCounters?
    private var previousNetwork: PillNetworkCounters?
    private var lastModel: PillModel?

    init(runtime: ExteralessPillRuntime, descriptor: PillDescriptor, update: @escaping (PillModel) -> Void) {
        self.runtime = runtime; self.descriptor = descriptor; self.update = update
    }
    deinit {
        self.native.dispose(); self.secondary.dispose(); self.remote?.cancel(); self.settingsObservation?.cancel()
        self.timer?.invalidate()
        self.retryTimer?.invalidate()
        for observer in self.notifications { NotificationCenter.default.removeObserver(observer) }
    }
    func start() {
        self.notifications = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.pause() } },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.resume() } }
        ]
        self.resume()
    }
    private func resume() {
        guard !self.cancelled, !self.active, self.runtime.lease.isValid, UIApplication.shared.applicationState == .active else { return }
        self.active = true
        self.refresh()
        var interval = self.descriptor.interval
        if interval > 0 && interval < 60 {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { interval = max(interval, 5) }
            if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { interval = max(interval, 10) }
        }
        if interval > 0 {
            self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            self.timer?.tolerance = min(5, max(0.5, interval / 10))
        }
    }
    private func pause() {
        self.active = false; self.job = UUID()
        self.timer?.invalidate(); self.timer = nil
        self.retryTimer?.invalidate(); self.retryTimer = nil
        self.native.set(nil); self.secondary.set(nil)
        self.remote?.cancel(); self.remote = nil
        self.location?.cancel(); self.location = nil
        self.settingsObservation?.cancel(); self.settingsObservation = nil
        self.previousCPU = nil; self.previousNetwork = nil
    }
    func cancel() {
        self.cancelled = true; self.pause()
        for observer in self.notifications { NotificationCenter.default.removeObserver(observer) }
        self.notifications.removeAll()
    }
    func invalidate() {
        self.update(.init(id: self.descriptor.id, title: "Account changed", value: "Reopen status pills", source: "Account lifecycle", phase: .unavailable))
        self.cancel()
    }
    private func current(_ job: UUID) -> Bool { self.active && !self.cancelled && self.job == job && self.runtime.lease.isValid }
    private func emit(_ model: PillModel, job: UUID) {
        guard self.current(job), (try? model.validate()) != nil else { return }
        self.lastModel = model; self.update(model)
    }
    private func model(_ value: String, detail: String = "", source: String, phase: PillPhase = .ready, timestamp: Date? = Date(), progress: Double? = nil, highlighted: Bool = false) -> PillModel {
        .init(id: self.descriptor.id, title: self.descriptor.title, value: value, detail: detail, source: source, phase: phase, updatedAt: timestamp, progress: progress, isHighlighted: highlighted)
    }

    func refresh(force: Bool = false) {
        guard self.active, self.runtime.lease.isValid else { return }
        if self.descriptor.id >= 10_000, self.descriptor.pair == nil, self.remote != nil {
            if !PluginPillBridgeActions.refresh(id: self.descriptor.id, scope: self.runtime.lease.scope, force: force) {
                PillPluginRegistry.shared.perform(.refresh, request: .init(id: self.descriptor.id, scope: self.runtime.lease.scope), lease: self.runtime.lease)
            }
            return
        }
        self.job = UUID()
        let job = self.job
        self.retryTimer?.invalidate(); self.retryTimer = nil
        self.native.set(nil); self.secondary.set(nil); self.remote?.cancel(); self.remote = nil
        self.location?.cancel(); self.location = nil
        if let pair = self.descriptor.pair { self.refreshRate(pair: pair, force: force, job: job); return }
        switch self.descriptor.id {
        case 1: self.refreshWeather(force: force, job: job)
        case 5: self.refreshCache(job: job)
        case 6: self.refreshConnection(isProxy: true, job: job)
        case 7:
            self.settingsObservation?.cancel()
            self.settingsObservation = ClientSettings.shared.observe { [weak self] keys in
                guard keys.isEmpty || keys.contains(where: { $0.hasPrefix("privacy.") }) else { return }
                DispatchQueue.main.async { [weak self] in self?.emitGhost(job: job) }
            }
            self.emitGhost(job: job)
        case 8: self.refreshMemory(job: job)
        case 9: self.refreshCPU(job: job)
        case 10: self.refreshNetwork(job: job)
        case 11: self.refreshConnection(isProxy: false, job: job)
        case 15: self.refreshLastSeen(job: job)
        default:
            self.remote = PillPluginRegistry.shared.subscribe(.init(id: self.descriptor.id, scope: self.runtime.lease.scope), lease: self.runtime.lease) { [weak self] model in
                DispatchQueue.main.async { [weak self] in self?.emit(model, job: job) }
            }
        }
    }

    private func refreshRate(pair: PillRatePair, force: Bool, job: UUID) {
        self.native.set((self.runtime.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.runtime.context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, self.current(job) else { return }
            var country: String?
            if case let .user(user)? = peer, let phone = user.phone {
                if phone.hasPrefix("76") || phone.hasPrefix("77") { country = "KZ" }
                else if phone.hasPrefix("7") { country = "RU" }
                else { country = lookupCountryIdByNumber(phone, configuration: self.runtime.context.currentCountriesConfiguration.with { $0 })?.0.id }
            }
            self.remote = self.runtime.rates.read(pair: pair, phoneCountry: country, force: force) { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current(job) else { return }
                    let quote = value.quote
                    let fresh = PillFreshness.isFresh(quote?.updatedAt, now: Date(), ttl: 300)
                    let phase: PillPhase = value.isLoading ? .loading : quote == nil ? .failed : value.error != nil || !fresh ? .stale : .ready
                    var detail = value.error?.localizedDescription ?? "One base unit in the selected currency. AUTO uses this account's phone-country."
                    if quote != nil && !fresh { detail += " Cached reading; its original observation time is shown below." }
                    if let error = value.cacheError { detail += " " + error }
                    self.emit(self.model(quote.map { PillCurrencies.text($0.value, currency: $0.pair.target) } ?? (value.isLoading ? "Loading…" : "Tap to retry"), detail: detail, source: quote?.source ?? (pair.base == "XAU" ? "gold-api.com + Coinbase" : "Coinbase"), phase: phase, timestamp: quote?.updatedAt), job: job)
                    if !value.isLoading { self.scheduleRetry(value.error, job: job) }
                }
            }
        }))
    }
    private func refreshWeather(force: Bool, job: UUID) {
        guard let config = try? self.runtime.configuration() else { return }
        let source = PillWeatherSource(rawValue: ClientSettings.shared.string("pills.weatherProvider", default: "telegram")) ?? .telegram
        let units = ClientSettings.shared.string("pills.weatherUnits", default: "AUTO")
        let fetch: (PillCoordinate) -> Void = { [weak self] coordinate in
            guard let self, self.current(job) else { return }
            self.remote = self.runtime.weather.read(coordinate: coordinate, source: source, force: force) { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current(job) else { return }
                    let reading = value.reading
                    let phase: PillPhase = value.isLoading ? .loading : reading == nil ? .failed : value.error != nil || !PillFreshness.isFresh(reading?.updatedAt, now: Date(), ttl: 900) ? .stale : .ready
                    let title = reading.map { $0.emoji + " " + $0.temperature(units: units) } ?? (value.isLoading ? "Loading…" : "Tap to retry")
                    self.emit(self.model(title, detail: value.error?.localizedDescription ?? (config.usesCurrentLocation ? "Current approximate location" : config.string("weatherAddress", fallback: "Manual coordinates")), source: source == .telegram ? "Telegram weather bot" : "Open-Meteo", phase: phase, timestamp: reading?.updatedAt), job: job)
                    if !value.isLoading { self.scheduleRetry(value.error, job: job) }
                }
            }
        }
        if !config.usesCurrentLocation {
            if let coordinate = config.coordinate { fetch(coordinate) }
            else { self.emit(self.model("Choose a location", detail: "Set valid manual coordinates in Weather settings.", source: "Weather configuration", phase: .unavailable, timestamp: nil), job: job) }
        } else {
            let location = ExteralessPillLocation(); self.location = location
            location.request(explicitAuthorization: false) { [weak self] result in
                guard let self, self.current(job) else { return }
                switch result {
                case let .success(coordinate): fetch(coordinate)
                case let .failure(error):
                    let text: String
                    switch error.reason {
                    case .needsPermission: text = "Enable location in Weather settings"
                    case .denied: text = "Location denied · choose a manual location"
                    case .timeout: text = "Location timed out · tap to retry"
                    case .unavailable: text = "Location unavailable · choose a manual location"
                    }
                    self.emit(self.model(text, source: "Core Location", phase: .unavailable, timestamp: nil), job: job)
                }
            }
        }
    }

    private func refreshCache(job: UUID) {
        self.native.set((combineLatest(self.runtime.context.engine.resources.storageTotalSize(), self.runtime.context.engine.resources.cacheStorageTotalSize())
        |> take(1) |> deliverOnMainQueue).start(next: { [weak self] media, cache in
            guard let self, self.current(job) else { return }
            let path = self.runtime.context.account.basePath
            ExteralessPillMetrics.queue.async { [weak self] in
                let disk = ExteralessPillMetrics.disk(path: path)
                let size = PillMetricPolicy.sumBytes([media, cache])
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current(job) else { return }
                    let detail = disk.map { "Device volume: \(ExteralessPillMetrics.bytes(UInt64($0.free))) free of \(ExteralessPillMetrics.bytes(UInt64($0.total))). Ring = occupied volume." } ?? "Device volume free space is unavailable."
                    self.emit(self.model(size.map(ExteralessPillMetrics.bytes) ?? "Unavailable", detail: detail, source: "Account MediaBox storage + cache; filesystem capacity", phase: size == nil ? .unavailable : .ready, progress: disk.flatMap { PillMetricPolicy.occupiedFraction(total: $0.total, free: $0.free) }), job: job)
                }
            }
        }))
    }
    private func scheduleRetry(_ error: PillError?, job: UUID) {
        guard self.current(job), let date = error?.retryDate else { return }
        let delay = date.timeIntervalSinceNow
        guard delay.isFinite, delay <= 3600 else { return }
        self.retryTimer?.invalidate()
        self.retryTimer = Foundation.Timer.scheduledTimer(withTimeInterval: max(1, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current(job) else { return }
                self.refresh()
            }
        }
        self.retryTimer?.tolerance = 1
    }
    private func emitGhost(job: UUID) {
        let policy = PrivacyPolicy.current
        self.emit(self.model(policy.ghostModeActive ? "On" : "Off", detail: "Tap to toggle the unlocked ghost-mode fields. Read and typing exceptions retain their existing account-scoped privacy policy.", source: "Core PrivacyPolicy", highlighted: policy.ghostModeActive), job: job)
    }
    private func refreshMemory(job: UUID) {
        ExteralessPillMetrics.queue.async { [weak self] in
            let memory = ExteralessPillMetrics.memory()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current(job) else { return }
                let free = memory.systemFreePages.map(ExteralessPillMetrics.bytes) ?? "not exposed"
                self.emit(self.model(memory.processFootprint.map { "App " + ExteralessPillMetrics.bytes($0) } ?? "App footprint unavailable", detail: "System free pages: \(free). Physical RAM: \(ExteralessPillMetrics.bytes(memory.physicalMemory)). Free pages exclude reclaimable/compressed memory; this is not Android's available-memory percentage.", source: "Mach TASK_VM_INFO / HOST_VM_INFO", phase: memory.processFootprint == nil ? .unavailable : .ready), job: job)
            }
        }
    }
    private func refreshCPU(job: UUID) {
        ExteralessPillMetrics.queue.async { [weak self] in
            let sample = ExteralessPillMetrics.cpu()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current(job) else { return }
                let percent = sample.flatMap { PillMetricPolicy.processCPU(previous: self.previousCPU, current: $0, processors: ProcessInfo.processInfo.activeProcessorCount) }
                self.previousCPU = sample
                self.emit(self.model(percent.map { String(format: "%.1f%% of one core", $0) } ?? (sample == nil ? "Unavailable" : "Measuring interval…"), detail: "Process user + system CPU time over the visible sampling interval. May exceed 100% on multiple cores; not whole-device CPU load.", source: "getrusage(RUSAGE_SELF) / monotonic uptime", phase: percent == nil ? .idle : .ready, timestamp: percent == nil ? nil : Date()), job: job)
            }
        }
    }
    private func refreshNetwork(job: UUID) {
        self.native.set((accountNetworkUsageStats(account: self.runtime.context.account, reset: []) |> take(1) |> runOn(Queue.concurrentDefaultQueue()) |> deliverOnMainQueue).start(next: { [weak self] stats in
            guard let self, self.current(job) else { return }
            let entries = [stats.generic, stats.image, stats.video, stats.audio, stats.file, stats.call, stats.sticker, stats.voiceMessage]
            guard let rx = PillMetricPolicy.sumBytes(entries.flatMap { [$0.wifi.incoming, $0.cellular.incoming] }), let tx = PillMetricPolicy.sumBytes(entries.flatMap { [$0.wifi.outgoing, $0.cellular.outgoing] }) else {
                self.previousNetwork = nil
                self.emit(self.model("Counters unavailable", source: "Account MTProto byte counters", phase: .unavailable, timestamp: nil), job: job); return
            }
            let sample = PillNetworkCounters(uptime: ProcessInfo.processInfo.systemUptime, received: rx, sent: tx, resetIdentity: "\(stats.resetWifiTimestamp):\(stats.resetCellularTimestamp)")
            let speed = PillMetricPolicy.networkSpeed(previous: self.previousNetwork, current: sample)
            self.previousNetwork = sample
            let text = speed.map { "↓\(ExteralessPillMetrics.speed($0.received)) ↑\(ExteralessPillMetrics.speed($0.sent))" } ?? "Measuring interval…"
            self.emit(self.model(text, detail: "This account since native counter reset: ↓\(ExteralessPillMetrics.bytes(rx)), ↑\(ExteralessPillMetrics.bytes(tx)). Includes native counted media/calls; excludes other apps and external provider HTTP. No packet-drop counter is exposed.", source: "Account MTProto byte counters (Wi-Fi + cellular)", phase: speed == nil ? .idle : .ready, timestamp: speed == nil ? nil : Date()), job: job)
        }))
    }
    private func refreshConnection(isProxy: Bool, job: UUID) {
        self.native.set((self.runtime.context.account.networkState |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.current(job) else { return }
            let text: String
            var connectedProxy = false
            switch state {
            case .waitingForNetwork: text = "Waiting for network"
            case let .connecting(proxy): text = isProxy && proxy == nil ? "Off · Connecting directly" : "Connecting"
            case let .updating(proxy): text = isProxy && proxy == nil ? "Off · Updating directly" : "Updating"
            case let .online(proxy):
                text = isProxy ? proxy.map { $0.hasConnectionIssues ? "Connection issues" : "Connected" } ?? "Off" : "Online"
                connectedProxy = proxy.map { !$0.hasConnectionIssues } ?? false
            }
            if isProxy {
                self.emit(self.model(text, detail: "Active account proxy connectivity. The native session does not expose a passive proxy RTT; open Proxy settings for its explicit connectivity test.", source: "Account networkState", highlighted: connectedProxy), job: job)
            } else {
                let dc = self.runtime.context.account.network.datacenterId
                self.emit(self.model("DC \(dc) · \(text)", detail: "Waiting for an existing native ping/pong sample; no probe is generated.", source: "MTProto main-session readiness"), job: job)
                self.secondary.set((combineLatest(exteralessPillConnectionActivity(account: self.runtime.context.account), exteralessPillPassivePing(account: self.runtime.context.account)) |> deliverOnMainQueue).start(next: { [weak self] activity, ping in
                    guard let self, self.current(job) else { return }
                    let connected: Bool
                    switch state { case .online, .updating: connected = true; default: connected = false }
                    if connected, let ping, ping.isFresh() {
                        self.emit(self.model("DC \(dc) · " + String(format: "%.3g ms", ping.roundTripSeconds * 1000), detail: "Last completed native ping/pong round trip. No extra request was sent by the pill.", source: "MTProto main-session passive pong RTT", timestamp: ping.sampledAt), job: job)
                    } else {
                        let silence = activity?.silentSeconds.map { String(format: "%.1f s", $0) } ?? "not exposed"
                        let waiting = activity?.waitingSeconds.map { String(format: "%.1f s", $0) } ?? "none reported"
                        self.emit(self.model("DC \(dc) · \(text)", detail: "Last server activity: \(silence) ago. Requests waiting: \(waiting). These are activity ages, not RTT. No current passive ping sample is exposed by this session.", source: "MTProto main-session serverActivity / readiness"), job: job)
                    }
                }))
            }
        }))
    }
    private func refreshLastSeen(job: UUID) {
        self.native.set((exteralessPillOwnStatus(engine: self.runtime.context.engine) |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self, self.current(job) else { return }
            var text = "Not observed"
            var timestamp: Date?
            var online = false
            var source = "Account server presence (cached)"
            if let status {
                switch status.presence {
                case let .online(until):
                    if Double(until) > Date().timeIntervalSince1970 { text = "Online (cached)"; online = true }
                    else { text = "Online observation expired" }
                case let .lastSeen(time): timestamp = Date(timeIntervalSince1970: Double(time))
                case .recently: text = "Recently"
                case .lastWeek: text = "Within a week"
                case .lastMonth: text = "Within a month"
                case .unknown: break
                }
                if !online, timestamp == nil, let observed = status.locallyObservedLastSeen {
                    timestamp = Date(timeIntervalSince1970: Double(observed)); source = "Account-scoped Privacy OwnLastSeen observation"
                }
            }
            if let timestamp { text = DateFormatter.localizedString(from: timestamp, dateStyle: Calendar.current.isDateInToday(timestamp) ? .none : .short, timeStyle: .short) }
            self.emit(self.model(text, detail: "Own account's existing native observations. Refresh re-reads them without sending online/read packets or querying another account.", source: source, phase: status == nil ? .unavailable : .ready, timestamp: timestamp, highlighted: online), job: job)
        }))
    }
}
