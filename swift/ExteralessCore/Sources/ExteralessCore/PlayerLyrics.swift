import Foundation

public enum PlayerLyricsLimits {
    public static let responseBytes = 1_048_576
    public static let textBytes = 262_144
    public static let lineBytes = 8192
    public static let lines = 4096
    public static let words = 32_768
    public static let candidates = 40
    public static let cacheEntries = 24
    public static let missingEntries = 128
    public static let overrideEntries = 64
    public static let cacheBytes = 4_194_304
    public static let maximumOffset = 60.0
    public static let maximumTrackDuration = Double(Int32.max)
}

public enum PlayerLyricsError: Error, Equatable, Sendable, LocalizedError {
    case cancelled, timeout, invalidQuery, invalidResponse, responseTooLarge, network, storage, busy
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Lyrics request cancelled."
        case .timeout: return "The lyrics request timed out. Try again."
        case .invalidQuery: return "This track has no usable title."
        case .invalidResponse: return "The lyrics service returned an invalid response."
        case .responseTooLarge: return "The lyrics response is too large."
        case .network: return "Couldn't reach the lyrics service."
        case .storage: return "Couldn't save the lyrics selection."
        case .busy: return "Another lyrics request is still finishing."
        case let .http(code): return "The lyrics service returned HTTP \(code)."
        }
    }

    static func sanitized(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorCancelled { return .cancelled }
            if error.code == NSURLErrorTimedOut { return .timeout }
        }
        return .network
    }
}

public struct PlayerLyricsDocument: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case file, online, user }
    public struct Word: Codable, Equatable, Sendable {
        public let time: Double
        public let text: String
        public init(time: Double, text: String) { self.time = time; self.text = text }
    }
    public struct Line: Codable, Equatable, Sendable {
        public let time: Double?
        public let text: String
        public let words: [Word]
        public init(time: Double?, text: String, words: [Word] = []) {
            self.time = time; self.text = text; self.words = words
        }
    }

    public let lines: [Line]
    public let synced: Bool
    public let instrumental: Bool
    public let source: Source
    public let provider: String

    public init(lines: [Line], synced: Bool, instrumental: Bool = false, source: Source, provider: String) {
        self.lines = lines
        self.synced = synced
        self.instrumental = instrumental
        self.source = source
        self.provider = String(provider.prefix(128))
    }

    public static func instrumental(source: Source = .online, provider: String) -> Self {
        Self(lines: [], synced: false, instrumental: true, source: source, provider: provider)
    }

    /// LRC offsets follow the original: a positive [offset:ms] makes a line
    /// earlier. A user delay is separate and never rewrites the provider's text.
    public static func parse(_ text: String, source: Source = .file, provider: String = "File") throws -> Self? {
        guard text.utf8.count <= PlayerLyricsLimits.textBytes else { throw PlayerLyricsError.responseTooLarge }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard rows.count <= PlayerLyricsLimits.lines else { throw PlayerLyricsError.responseTooLarge }
        var timed: [(Int, Line)] = []
        var plain: [Line] = []
        var offset = 0.0
        var wordCount = 0
        for row in rows {
            let row = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.utf8.count <= PlayerLyricsLimits.lineBytes else { throw PlayerLyricsError.responseTooLarge }
            if row.lowercased().hasPrefix("[offset:"), let end = row.firstIndex(of: "]") {
                let value = row[row.index(row.startIndex, offsetBy: 8)..<end].trimmingCharacters(in: .whitespaces)
                if let milliseconds = Double(value), milliseconds.isFinite, abs(milliseconds) <= 3_600_000 { offset = milliseconds / 1000 }
                continue
            }
            var remainder = row[...]
            var times: [Double] = []
            while remainder.first == "[", let end = remainder.firstIndex(of: "]"), let time = parseTime(remainder[remainder.index(after: remainder.startIndex)..<end]) {
                guard times.count < 64 else { throw PlayerLyricsError.responseTooLarge }
                times.append(time)
                remainder = remainder[remainder.index(after: end)...]
            }
            if !times.isEmpty {
                let content = parseWords(String(remainder), offset: offset)
                wordCount += content.words.count * times.count
                guard timed.count + times.count <= PlayerLyricsLimits.lines, wordCount <= PlayerLyricsLimits.words else { throw PlayerLyricsError.responseTooLarge }
                for time in times {
                    timed.append((timed.count, Line(time: max(0, time - offset), text: content.text, words: content.words)))
                }
            } else if !(row.hasPrefix("[") && row.hasSuffix("]") && row.contains(":")) {
                if !row.isEmpty || plain.last?.text.isEmpty == false { plain.append(Line(time: nil, text: row)) }
            }
        }
        if !timed.isEmpty {
            timed.sort { lhs, rhs in
                let l = lhs.1.time ?? 0, r = rhs.1.time ?? 0
                return l == r ? lhs.0 < rhs.0 : l < r
            }
            var lines: [Line] = []
            for (_, line) in timed {
                if line.text.isEmpty && (lines.isEmpty || lines.last?.text.isEmpty == true) { continue }
                lines.append(line)
            }
            while lines.last?.text.isEmpty == true { lines.removeLast() }
            return lines.isEmpty ? nil : Self(lines: lines, synced: true, source: source, provider: provider)
        }
        while plain.last?.text.isEmpty == true { plain.removeLast() }
        return plain.isEmpty ? nil : Self(lines: plain, synced: false, source: source, provider: provider)
    }

    private static func parseTime(_ raw: Substring) -> Double? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, (1...3).contains(parts[0].count), parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), let minutes = Int(parts[0]) else { return nil }
        let secondsParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard secondsParts.count <= 2, (1...2).contains(secondsParts[0].count), secondsParts[0].allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int(secondsParts[0]), seconds < 60 else { return nil }
        let fraction: Substring? = parts.count == 3 ? parts[2] : (secondsParts.count == 2 ? secondsParts[1] : nil)
        var value = Double(minutes * 60 + seconds)
        if let fraction {
            guard (1...3).contains(fraction.count), fraction.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(fraction) else { return nil }
            value += Double(number) / pow(10, Double(fraction.count))
        }
        return value
    }

    private static func parseWords(_ text: String, offset: Double) -> (text: String, words: [Word]) {
        var content = ""
        var words: [Word] = []
        var remainder = text[...]
        var wordTime: Double?
        while let start = remainder.firstIndex(of: "<"), let end = remainder[start...].firstIndex(of: ">"), let time = parseTime(remainder[remainder.index(after: start)..<end]) {
            let segment = String(remainder[..<start])
            content += segment
            if let wordTime, !segment.isEmpty { words.append(Word(time: max(0, wordTime - offset), text: segment)) }
            wordTime = time
            remainder = remainder[remainder.index(after: end)...]
        }
        content += remainder
        if let wordTime, !remainder.isEmpty { words.append(Word(time: max(0, wordTime - offset), text: String(remainder))) }
        // Only real monotonically timed word markers become karaoke cues.
        if zip(words, words.dropFirst()).contains(where: { $0.0.time > $0.1.time }) { words.removeAll() }
        return (content.trimmingCharacters(in: .whitespaces), words)
    }

    public func index(at playbackTime: Double, userOffset: Double = 0) -> Int? {
        guard synced, playbackTime.isFinite, userOffset.isFinite else { return nil }
        let time = playbackTime - Self.clampedOffset(userOffset)
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if (lines[middle].time ?? .infinity) <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    public func seekTime(line: Int, userOffset: Double, duration: Double) -> Double? {
        guard synced, lines.indices.contains(line), let time = lines[line].time else { return nil }
        return ChatPlaybackPolicy.seekPosition(timestamp: time, delta: Self.clampedOffset(userOffset), duration: duration)
    }

    public static func clampedOffset(_ value: Double) -> Double {
        value.isFinite ? min(PlayerLyricsLimits.maximumOffset, max(-PlayerLyricsLimits.maximumOffset, value)) : 0
    }

    public var text: String {
        lines.map { line in
            guard synced, let time = line.time, time.isFinite else { return line.text }
            let milliseconds = Int64(max(0, min(time, 60_000)) * 1000)
            return String(format: "[%02lld:%02lld.%03lld]", milliseconds / 60_000, milliseconds / 1000 % 60, milliseconds % 1000) + line.text
        }.joined(separator: "\n")
    }

    var isValid: Bool {
        guard lines.count <= PlayerLyricsLimits.lines, provider.utf8.count <= 512 else { return false }
        var bytes = 0, words = 0
        var previous = -Double.infinity
        for line in lines {
            guard line.text.utf8.count <= PlayerLyricsLimits.lineBytes else { return false }
            bytes += line.text.utf8.count
            words += line.words.count
            if synced {
                guard let time = line.time, time.isFinite, time >= 0, time >= previous, time < 64_000 else { return false }
                previous = time
            }
            guard line.words.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < 64_000 }) else { return false }
        }
        return bytes <= PlayerLyricsLimits.textBytes && words <= PlayerLyricsLimits.words && (instrumental || !lines.isEmpty)
    }
}

public struct PlayerLyricsQuery: Codable, Hashable, Sendable {
    public let artist: String
    public let title: String
    public let album: String
    public let duration: Int

    public init(artist: String?, title: String?, album: String? = nil, duration: Double) {
        var artist = Self.clean(artist)
        var title = Self.clean(title)
        title = title.replacingOccurrences(of: "\\.(mp3|m4a|flac|ogg|oga|opus|wav|aac|alac|wma)$", with: "", options: [.regularExpression, .caseInsensitive]).replacingOccurrences(of: "_", with: " ")
        if artist.isEmpty, let dash = title.range(of: " - "), dash.lowerBound != title.startIndex {
            artist = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            title = String(title[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let stripped = title.replacingOccurrences(of: "\\s*[(\\[][^)\\]]*(official|lyric|video|audio|visualizer|remaster|hq|hd)[^)\\]]*[)\\]]", with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        self.artist = artist
        self.title = stripped.isEmpty ? title : stripped
        self.album = Self.clean(album)
        self.duration = duration.isFinite && duration > 0 ? Int(min(PlayerLyricsLimits.maximumTrackDuration, duration.rounded())) : 0
    }

    public var valid: Bool { !title.isEmpty }

    private static func clean(_ value: String?) -> String {
        String((value ?? "").prefix(512)).components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Account + media resource + exact duration prevents same-title tracks, edited
/// media and account switches from sharing a lyric selection or user offset.
public struct PlayerLyricsTrack: Codable, Hashable, Sendable {
    public let account: Int64
    public let resource: String
    public let durationMilliseconds: Int64
    public let query: PlayerLyricsQuery

    public init(account: Int64, resource: String, duration: Double, query: PlayerLyricsQuery) {
        self.account = account
        self.resource = String(resource.prefix(1024))
        self.durationMilliseconds = duration.isFinite && duration > 0 ? Int64(min(PlayerLyricsLimits.maximumTrackDuration, duration) * 1000) : 0
        self.query = query
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account == rhs.account && lhs.resource == rhs.resource && lhs.durationMilliseconds == rhs.durationMilliseconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(account)
        hasher.combine(resource)
        hasher.combine(durationMilliseconds)
    }
}

public struct PlayerLyricsCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double?
    public let lyrics: PlayerLyricsDocument

    public init(id: String, title: String, artist: String, album: String, duration: Double?, lyrics: PlayerLyricsDocument) {
        self.id = String(id.prefix(128)); self.title = String(title.prefix(512)); self.artist = String(artist.prefix(512)); self.album = String(album.prefix(512))
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.lyrics = lyrics
    }
}

public enum PlayerLyricsMatching {
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func similarity(_ left: String, _ right: String) -> Double {
        let lhs = Set(words(left)), rhs = Set(words(right))
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(max(lhs.count, rhs.count))
    }

    /// Retains Android's synced +40 / duration-3s scoring, then rejects clearly
    /// mismatched titles/artists instead of accepting the first remote search hit.
    public static func score(_ candidate: PlayerLyricsCandidate, query: PlayerLyricsQuery) -> Double? {
        let title = similarity(candidate.title, query.title)
        let artist = query.artist.isEmpty ? 1 : similarity(candidate.artist, query.artist)
        guard title >= 0.5, artist >= 0.35 || candidate.artist.isEmpty else { return nil }
        var score = candidate.lyrics.synced ? 40.0 : 0
        score += title * 60 + artist * 20
        if query.duration > 0, let duration = candidate.duration {
            let difference = abs(duration.rounded() - Double(query.duration))
            // A totally different recording must require an explicit selection.
            guard difference <= max(20, Double(query.duration) * 0.15) else { return nil }
            score -= difference <= 3 ? difference : 20 + min(difference, 60)
        }
        if !query.album.isEmpty { score += similarity(candidate.album, query.album) * 5 }
        return score
    }

    public static func best(_ candidates: [PlayerLyricsCandidate], query: PlayerLyricsQuery) -> PlayerLyricsCandidate? {
        var best: PlayerLyricsCandidate?, bestScore = -Double.infinity
        for candidate in candidates.prefix(PlayerLyricsLimits.candidates) {
            if let score = score(candidate, query: query), score > bestScore { best = candidate; bestScore = score }
        }
        return best
    }

    /// Original LRCMUX/LRCLIB punctuation alignment: four-token lookahead and
    /// >=90% matched words, while retaining provider timestamps and line breaks.
    public static func punctuate(timed: PlayerLyricsDocument, plain: PlayerLyricsDocument) -> PlayerLyricsDocument? {
        let tokens = plain.lines.flatMap { $0.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }.prefix(PlayerLyricsLimits.words)
        let pairs = tokens.map { ($0, words($0).joined()) }.filter { !$0.1.isEmpty }
        guard !pairs.isEmpty else { return nil }
        var position = 0, total = 0, matched = 0
        var lines: [PlayerLyricsDocument.Line] = []
        for line in timed.lines {
            let tokens = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var updated: [String] = []
            for token in tokens {
                let key = words(token).joined()
                if key.isEmpty { updated.append(token); continue }
                total += 1
                if let index = (position..<min(position + 4, pairs.count)).first(where: { pairs[$0].1 == key }) {
                    var replacement = pairs[index].0
                    if let originalLetter = token.first(where: { $0.isLetter }), let first = replacement.firstIndex(where: { $0.isLetter }) {
                        let letter = String(replacement[first])
                        replacement.replaceSubrange(first...first, with: originalLetter.isUppercase ? letter.uppercased() : letter.lowercased())
                    }
                    updated.append(replacement)
                    position = index + 1
                    matched += 1
                } else { updated.append(token) }
            }
            lines.append(.init(time: line.time, text: updated.joined(separator: " ")))
        }
        guard total > 0, Double(matched) >= Double(total) * 0.9 else { return nil }
        return PlayerLyricsDocument(lines: lines, synced: true, source: timed.source, provider: timed.provider + " + LRCLIB")
    }
}

/// A late result may only update the exact track/duration generation that asked
/// for it, even when cancellation races URLSession or local metadata loading.
public struct PlayerLyricsGeneration: Sendable {
    public struct Token: Equatable, Sendable {
        public let generation: UInt64
        public let track: PlayerLyricsTrack
    }
    private var generation: UInt64 = 0
    private var track: PlayerLyricsTrack?
    public init() {}
    public mutating func begin(_ track: PlayerLyricsTrack) -> Token {
        generation &+= 1
        self.track = track
        return Token(generation: generation, track: track)
    }
    public mutating func cancel() { generation &+= 1; track = nil }
    public func accepts(_ token: Token) -> Bool { token.generation == generation && token.track == track }
}
