import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PlayerLyricsResult: Sendable {
    public enum State: Equatable, Sendable { case lyrics, offerOnline, notFound }
    public let state: State
    public let lyrics: PlayerLyricsDocument?
    public let candidates: [PlayerLyricsCandidate]
    public let userOffset: Double
    public let isUserSelection: Bool
    /// An embedded/plain result may survive a failed online upgrade.
    public let warning: PlayerLyricsError?
}

public struct PlayerLyricsOverride: Codable, Equatable, Sendable {
    public var lyrics: PlayerLyricsDocument?
    public var offset: Double
    public init(lyrics: PlayerLyricsDocument? = nil, offset: Double = 0) {
        self.lyrics = lyrics; self.offset = PlayerLyricsDocument.clampedOffset(offset)
    }
}

/// Actor-isolated caches and persistence; URLSession awaits never block UIKit.
/// The whole lookup (all providers and retries) has one monotonic 20-second budget.
public actor PlayerLyricsClient {
    private struct CacheEntry: Codable {
        let track: PlayerLyricsTrack
        let lyrics: PlayerLyricsDocument
        let candidates: [PlayerLyricsCandidate]
        var accessed: Date
    }
    private struct OverrideEntry: Codable {
        let track: PlayerLyricsTrack
        var value: PlayerLyricsOverride
        var accessed: Date
    }
    private struct Archive: Codable {
        let version: Int
        var entries: [CacheEntry]
        var overrides: [OverrideEntry]
    }
    private let transport: any PlayerLyricsHTTPTransport
    private let cacheURL: URL?
    private let timeout: TimeInterval
    private let retryDelays: [TimeInterval]
    private var loaded = false
    private var entries: [CacheEntry] = []
    private var overrides: [OverrideEntry] = []
    private var missing: [PlayerLyricsTrack: Date] = [:]
    private var generation: UInt64 = 0
    private var activeRequests = 0

    public init(transport: any PlayerLyricsHTTPTransport = PlayerLyricsURLSessionTransport(), cacheURL: URL? = nil, timeout: TimeInterval = 20, retryDelays: [TimeInterval] = [0.7, 2]) {
        self.transport = transport
        self.cacheURL = cacheURL?.isFileURL == true ? cacheURL : nil
        self.timeout = timeout.isFinite ? max(0.05, min(20, timeout)) : 20
        self.retryDelays = Array(retryDelays.prefix(2)).map { $0.isFinite ? min(5, max(0, $0)) : 0 }
    }

    public func lookup(track: PlayerLyricsTrack, onlineAllowed: Bool, embedded: PlayerLyricsDocument? = nil, refresh: Bool = false) async throws -> PlayerLyricsResult {
        try Task.checkCancellation()
        loadCache()
        let revision = generation
        let override = overrides.first(where: { $0.track == track })?.value
        if let lyrics = override?.lyrics {
            return result(lyrics: lyrics, candidates: [], override: override)
        }
        if let embedded, embedded.synced || embedded.instrumental {
            return result(lyrics: embedded, candidates: [], override: override)
        }
        if !refresh, let index = entries.firstIndex(where: { $0.track == track }) {
            entries[index].accessed = Date()
            let cached = entries[index]
            if embedded == nil || cached.lyrics.synced { return result(lyrics: cached.lyrics, candidates: cached.candidates, override: override) }
        }
        guard track.query.valid else {
            if let embedded { return result(lyrics: embedded, candidates: [], override: override) }
            throw PlayerLyricsError.invalidQuery
        }
        guard onlineAllowed else {
            return PlayerLyricsResult(state: embedded == nil ? .offerOnline : .lyrics, lyrics: embedded, candidates: [], userOffset: override?.offset ?? 0, isUserSelection: false, warning: nil)
        }
        if !refresh, let until = missing[track], until > Date() {
            return result(lyrics: embedded, candidates: [], override: override)
        }
        guard activeRequests < 3 else { throw PlayerLyricsError.busy }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var candidates: [PlayerLyricsCandidate] = []
        var primary: PlayerLyricsDocument?
        var failure: PlayerLyricsError?
        do {
            if !track.query.artist.isEmpty, let data = try await get(track.query, endpoint: .exact, deadline: deadline) {
                if let candidate = try decodeExact(data), PlayerLyricsMatching.score(candidate, query: track.query) != nil {
                    candidates = [candidate]
                    primary = candidate.lyrics
                }
            }
            if primary == nil, let data = try await get(track.query, endpoint: .search, deadline: deadline) {
                candidates = try decodeSearch(data)
                primary = PlayerLyricsMatching.best(candidates, query: track.query)?.lyrics
            }
        } catch {
            failure = try recoverable(error)
        }
        var lyrics = primary
        if primary?.synced != true && primary?.instrumental != true {
            do {
                if let data = try await get(track.query, endpoint: .fallback, deadline: deadline), let fallback = try decodeFallback(data, query: track.query) {
                    if fallback.lyrics.synced || primary == nil {
                        lyrics = fallback.lyrics
                        if let primary, fallback.lyrics.synced {
                            lyrics = PlayerLyricsMatching.punctuate(timed: fallback.lyrics, plain: primary) ?? fallback.lyrics
                        }
                    }
                    candidates.append(fallback)
                }
            } catch {
                failure = try recoverable(error)
            }
        }
        try Task.checkCancellation()
        guard revision == generation else { throw PlayerLyricsError.cancelled }
        if let lyrics {
            entries.removeAll { $0.track == track }
            entries.append(CacheEntry(track: track, lyrics: lyrics, candidates: Array(candidates.prefix(PlayerLyricsLimits.candidates)), accessed: Date()))
            missing.removeValue(forKey: track)
            trimCache()
            // A cache write failure must not hide an otherwise usable lyric.
            try? persist()
        } else if failure == nil {
            missing[track] = Date().addingTimeInterval(15 * 60)
            if missing.count > PlayerLyricsLimits.missingEntries, let oldest = missing.min(by: { $0.value < $1.value })?.key { missing.removeValue(forKey: oldest) }
        }
        if let embedded, lyrics?.synced != true { lyrics = embedded }
        if lyrics == nil, let failure { throw failure }
        return result(lyrics: lyrics, candidates: candidates, override: override, warning: failure)
    }

    /// Explicit candidate selection uses the same bounded search and preserves
    /// that exact selected lyric as an override; it never guesses a new queue item.
    public func search(query: PlayerLyricsQuery, onlineAllowed: Bool) async throws -> [PlayerLyricsCandidate] {
        guard onlineAllowed else { return [] }
        guard activeRequests < 3 else { throw PlayerLyricsError.busy }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let revision = generation
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let data = try await get(query, endpoint: .search, deadline: deadline) else { return [] }
        try Task.checkCancellation()
        guard revision == generation else { throw PlayerLyricsError.cancelled }
        return try decodeSearch(data).sorted { (PlayerLyricsMatching.score($0, query: query) ?? -.infinity) > (PlayerLyricsMatching.score($1, query: query) ?? -.infinity) }
    }

    public func setOverride(_ value: PlayerLyricsOverride?, for track: PlayerLyricsTrack) throws {
        try Task.checkCancellation()
        loadCache()
        if let lyrics = value?.lyrics, !lyrics.isValid { throw PlayerLyricsError.invalidResponse }
        let previous = overrides
        overrides.removeAll { $0.track == track }
        if var value {
            value.offset = PlayerLyricsDocument.clampedOffset(value.offset)
            overrides.append(OverrideEntry(track: track, value: value, accessed: Date()))
        }
        overrides = Array(overrides.sorted { $0.accessed > $1.accessed }.prefix(PlayerLyricsLimits.overrideEntries))
        do { try persist() }
        catch { overrides = previous; throw PlayerLyricsError.storage }
    }

    public func userOverride(for track: PlayerLyricsTrack) -> PlayerLyricsOverride? {
        loadCache()
        return overrides.first(where: { $0.track == track })?.value
    }

    /// Account teardown invalidates in-flight cache writes. Each view also cancels
    /// its task, which closes its URLSession immediately through the transport.
    public func invalidate() { generation &+= 1; entries.removeAll(); missing.removeAll(); overrides.removeAll(); loaded = false }

    public func cacheCounts() -> (lyrics: Int, missing: Int, overrides: Int) { (entries.count, missing.count, overrides.count) }

    private func result(lyrics: PlayerLyricsDocument?, candidates: [PlayerLyricsCandidate], override: PlayerLyricsOverride?, warning: PlayerLyricsError? = nil) -> PlayerLyricsResult {
        PlayerLyricsResult(state: lyrics == nil ? .notFound : .lyrics, lyrics: lyrics, candidates: Array(candidates.prefix(PlayerLyricsLimits.candidates)), userOffset: override?.offset ?? 0, isUserSelection: override?.lyrics != nil, warning: warning)
    }

    private func recoverable(_ error: Error) throws -> PlayerLyricsError {
        let error = PlayerLyricsError.sanitized(error)
        if error == .cancelled { throw error }
        return error
    }

    private func get(_ query: PlayerLyricsQuery, endpoint: PlayerLyricsRequest.Endpoint, deadline: TimeInterval) async throws -> Data? {
        var failure = PlayerLyricsError.network
        var delay = 0.0
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > delay else { throw PlayerLyricsError.timeout }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PlayerLyricsError.timeout }
            let request = try PlayerLyricsRequest.make(query: query, endpoint: endpoint, timeout: min(10, remaining))
            delay = retryDelays.isEmpty ? 0 : retryDelays[min(attempt, retryDelays.count - 1)]
            do {
                let response = try await transport.send(request, timeout: min(10, remaining))
                try Task.checkCancellation()
                if response.status == 404 { return nil }
                if (200..<300).contains(response.status) {
                    guard response.data.count <= PlayerLyricsLimits.responseBytes else { throw PlayerLyricsError.responseTooLarge }
                    guard let first = response.data.first(where: { ![9, 10, 13, 32].contains($0) }), first == 91 || first == 123 else { throw PlayerLyricsError.invalidResponse }
                    return response.data
                }
                let transient = [408, 425, 429].contains(response.status) || (500..<600).contains(response.status)
                guard transient else { throw PlayerLyricsError.http(response.status) }
                failure = .http(response.status)
                if let retryAfter = response.retryAfter, let seconds = Double(retryAfter), seconds.isFinite, seconds > 0 { delay = min(5, seconds) }
            } catch {
                let error = PlayerLyricsError.sanitized(error)
                switch error {
                case .network, .timeout, .invalidResponse: failure = error
                default: throw error
                }
            }
        }
        throw failure
    }

    private struct LRCLIB: Decodable {
        let id: Int64?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private func candidate(_ value: LRCLIB) throws -> PlayerLyricsCandidate? {
        let lyrics: PlayerLyricsDocument?
        if value.instrumental == true { lyrics = .instrumental(provider: "LRCLIB") }
        else {
            let synced = try PlayerLyricsDocument.parse(value.syncedLyrics ?? "", source: .online, provider: "LRCLIB")
            if synced?.synced == true { lyrics = synced }
            else { lyrics = try PlayerLyricsDocument.parse(value.plainLyrics ?? "", source: .online, provider: "LRCLIB") ?? synced }
        }
        guard let lyrics else { return nil }
        return PlayerLyricsCandidate(id: "lrclib:\(value.id ?? 0)", title: value.trackName ?? "", artist: value.artistName ?? "", album: value.albumName ?? "", duration: value.duration, lyrics: lyrics)
    }

    private func decodeExact(_ data: Data) throws -> PlayerLyricsCandidate? {
        do { return try candidate(JSONDecoder().decode(LRCLIB.self, from: data)) }
        catch let error as PlayerLyricsError { throw error }
        catch { throw PlayerLyricsError.invalidResponse }
    }

    private func decodeSearch(_ data: Data) throws -> [PlayerLyricsCandidate] {
        do {
            let values = try JSONDecoder().decode([LRCLIB].self, from: data)
            var result: [PlayerLyricsCandidate] = []
            for value in values.prefix(PlayerLyricsLimits.candidates) {
                if let candidate = try candidate(value) { result.append(candidate) }
            }
            return result
        } catch let error as PlayerLyricsError { throw error }
        catch { throw PlayerLyricsError.invalidResponse }
    }

    private struct LRCMUX: Decodable {
        struct Track: Decodable { let title: String?; let artist: String?; let album: String?; let duration: Double? }
        struct Meta: Decodable {
            struct Source: Decodable { let name: String? }
            let source: Source?; let instrumental: Bool?; let level: String?
        }
        struct Line: Decodable { let start: Double?; let text: String? }
        let track: Track?; let meta: Meta?; let lines: [Line]?
    }

    private func decodeFallback(_ data: Data, query: PlayerLyricsQuery) throws -> PlayerLyricsCandidate? {
        let value: LRCMUX
        do { value = try JSONDecoder().decode(LRCMUX.self, from: data) }
        catch { throw PlayerLyricsError.invalidResponse }
        if query.duration > 0, let duration = value.track?.duration, duration > 0, abs(duration - Double(query.duration)) > 5 { return nil }
        let provider = "lrcmux" + (value.meta?.source?.name.map { " · " + String($0.prefix(64)) } ?? "")
        let lyrics: PlayerLyricsDocument
        if value.meta?.instrumental == true { lyrics = .instrumental(provider: provider) }
        else {
            let raw = value.lines ?? []
            guard raw.count <= PlayerLyricsLimits.lines else { throw PlayerLyricsError.responseTooLarge }
            let synced = value.meta != nil && value.meta?.level != "none"
            var text = ""
            for line in raw {
                if synced {
                    guard let start = line.start, start.isFinite, start >= 0, start < 64_000_000 else { throw PlayerLyricsError.invalidResponse }
                    let milliseconds = Int64(start)
                    text += String(format: "[%02lld:%02lld.%03lld]", milliseconds / 60_000, milliseconds / 1000 % 60, milliseconds % 1000)
                }
                text += (line.text ?? "") + "\n"
                guard text.utf8.count <= PlayerLyricsLimits.textBytes else { throw PlayerLyricsError.responseTooLarge }
            }
            guard let parsed = try PlayerLyricsDocument.parse(text, source: .online, provider: provider) else { return nil }
            lyrics = parsed
        }
        let candidate = PlayerLyricsCandidate(id: "lrcmux", title: value.track?.title ?? query.title, artist: value.track?.artist ?? query.artist, album: value.track?.album ?? query.album, duration: value.track?.duration, lyrics: lyrics)
        return PlayerLyricsMatching.score(candidate, query: query) == nil ? nil : candidate
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let file = try? FileHandle(forReadingFrom: cacheURL) else { return }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: PlayerLyricsLimits.cacheBytes + 1), data.count <= PlayerLyricsLimits.cacheBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else { return }
        entries = archive.entries.filter { $0.lyrics.isValid && Date().timeIntervalSince($0.accessed) < 30 * 24 * 60 * 60 }.prefix(PlayerLyricsLimits.cacheEntries).map { entry in
            CacheEntry(track: entry.track, lyrics: entry.lyrics, candidates: Array(entry.candidates.filter { $0.lyrics.isValid }.prefix(PlayerLyricsLimits.candidates)), accessed: entry.accessed)
        }
        overrides = Array(archive.overrides.filter { $0.value.offset.isFinite && ($0.value.lyrics?.isValid ?? true) }.prefix(PlayerLyricsLimits.overrideEntries))
    }

    private func trimCache() {
        entries = Array(entries.sorted { $0.accessed > $1.accessed }.prefix(PlayerLyricsLimits.cacheEntries))
        let encoder = JSONEncoder()
        while !entries.isEmpty, ((try? encoder.encode(entries).count) ?? Int.max) > PlayerLyricsLimits.cacheBytes {
            entries.removeLast()
        }
    }

    private func persist() throws {
        guard let cacheURL else { return }
        let encoder = JSONEncoder()
        var archive = Archive(version: 1, entries: entries, overrides: overrides)
        var data = try encoder.encode(archive)
        while data.count > PlayerLyricsLimits.cacheBytes && !archive.entries.isEmpty {
            archive.entries.removeLast()
            data = try encoder.encode(archive)
        }
        // Never evict a user's selection merely to fit an automatic cache entry.
        guard data.count <= PlayerLyricsLimits.cacheBytes else { throw PlayerLyricsError.storage }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        entries = archive.entries
    }
}
