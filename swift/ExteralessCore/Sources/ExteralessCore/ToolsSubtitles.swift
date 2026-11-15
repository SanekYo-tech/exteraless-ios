import Foundation

public struct ToolsSubtitleTrack: Sendable, Equatable {
    public struct Cue: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
    }
    public let cues: [Cue]
    private let endPrefix: [TimeInterval]
    public static let maximumBytes = 1_024 * 1_024

    /// Bounded SRT/WebVTT sidecars. Cue identifiers and WebVTT positioning are
    /// ignored; text is rendered by a native label, never an HTML/WebView engine.
    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ToolsError.unavailable("Subtitles must be a UTF-8 .srt or .vtt file up to 1 MiB.")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if lines.first?.hasPrefix("NOTE") == true || lines.first == "STYLE" || lines.first == "REGION" { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = Self.timestamp(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = timing[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = Self.timestamp(String(endToken)), start < end else {
                throw ToolsError.unavailable("The subtitle file contains an invalid time range.")
            }
            let raw = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
            guard raw.utf8.count <= 16_384, cues.count < 10_000 else { throw ToolsError.sizeLimit }
            let plain = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            if !plain.isEmpty { cues.append(Cue(start: start, end: end, text: plain)) }
        }
        guard !cues.isEmpty else { throw ToolsError.unavailable("No SRT/WebVTT subtitle cues were found.") }
        cues.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        self.cues = cues
        var maximum: TimeInterval = 0
        self.endPrefix = cues.map { maximum = max(maximum, $0.end); return maximum }
    }

    public func text(at time: TimeInterval) -> String? {
        guard time.isFinite, time >= 0 else { return nil }
        var lower = 0, upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        var index = lower - 1
        var active: [String] = []
        while index >= 0 && endPrefix[index] > time && active.count < 4 {
            if cues[index].end > time { active.append(cues[index].text) }
            index -= 1
        }
        return active.isEmpty ? nil : active.reversed().joined(separator: "\n")
    }

    private static func timestamp(_ string: String) -> TimeInterval? {
        guard string.utf8.count <= 32 else { return nil }
        let fields = string.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let seconds = fields.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard seconds.count == 2, seconds[1].count == 3,
              let second = Int(seconds[0]), (0..<60).contains(second), let milliseconds = Int(seconds[1]),
              (0..<1_000).contains(milliseconds), let minutes = Int(fields[fields.count - 2]), (0..<60).contains(minutes) else { return nil }
        let hours = fields.count == 3 ? Int(fields[0]) : 0
        guard let hours, (0...168).contains(hours) else { return nil }
        return Double(hours * 3_600 + minutes * 60 + second) + Double(milliseconds) / 1_000
    }
}
