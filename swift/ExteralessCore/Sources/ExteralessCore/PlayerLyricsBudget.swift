import Foundation

/// Counts logical content, including repeated LRC timestamps and the second copy
/// of text in enhanced word cues. Admission happens before appending expanded rows.
struct PlayerLyricsContentBudget {
    private let maximumBytes: Int
    private let maximumWords: Int
    private let maximumLines: Int
    private(set) var logicalBytes = 0
    private(set) var wordCount = 0
    private(set) var lineCount = 0

    init(maximumBytes: Int = PlayerLyricsLimits.textBytes, maximumWords: Int = PlayerLyricsLimits.words, maximumLines: Int = PlayerLyricsLimits.lines) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumWords = max(0, maximumWords)
        self.maximumLines = max(0, maximumLines)
    }

    mutating func admit(textBytes: Int, wordTextBytes: Int, words: Int, repetitions: Int = 1) throws {
        guard repetitions > 0, textBytes >= 0, wordTextBytes >= 0, words >= 0,
              textBytes <= PlayerLyricsLimits.lineBytes,
              wordTextBytes <= PlayerLyricsLimits.lineBytes,
              textBytes <= (maximumBytes - logicalBytes) / repetitions,
              wordTextBytes <= (maximumBytes - logicalBytes) / repetitions - textBytes,
              words <= (maximumWords - wordCount) / repetitions,
              repetitions <= maximumLines - lineCount else { throw PlayerLyricsError.responseTooLarge }
        logicalBytes += (textBytes + wordTextBytes) * repetitions
        wordCount += words * repetitions
        lineCount += repetitions
    }
}

struct PlayerLyricsFootprint {
    let logicalBytes: Int
    let words: Int
    let lines: Int
    /// JSON escaping costs at most six bytes per UTF-8 byte. Fixed overheads also
    /// cover keys, separators and validated finite numeric timestamps.
    let encodedUpperBound: Int
}

extension PlayerLyricsDocument {
    func checkedFootprint() throws -> PlayerLyricsFootprint {
        guard lines.count <= PlayerLyricsLimits.lines, provider.utf8.count <= 512 else { throw PlayerLyricsError.responseTooLarge }
        guard instrumental || !lines.isEmpty else { throw PlayerLyricsError.invalidResponse }
        var budget = PlayerLyricsContentBudget()
        var previous = -Double.infinity
        for line in lines {
            guard line.words.count <= PlayerLyricsLimits.words else { throw PlayerLyricsError.responseTooLarge }
            var wordBytes = 0
            var previousWord = -Double.infinity
            for word in line.words {
                let bytes = word.text.utf8.count
                guard bytes <= PlayerLyricsLimits.lineBytes - wordBytes else { throw PlayerLyricsError.responseTooLarge }
                wordBytes += bytes
                guard word.time.isFinite, word.time >= 0, word.time >= previousWord, word.time < 64_000 else { throw PlayerLyricsError.invalidResponse }
                previousWord = word.time
            }
            try budget.admit(textBytes: line.text.utf8.count, wordTextBytes: wordBytes, words: line.words.count)
            if synced {
                guard let time = line.time, time.isFinite, time >= 0, time >= previous, time < 64_000 else { throw PlayerLyricsError.invalidResponse }
                previous = time
            } else if let time = line.time, !time.isFinite || time < 0 || time >= 64_000 {
                throw PlayerLyricsError.invalidResponse
            }
        }
        return PlayerLyricsFootprint(logicalBytes: budget.logicalBytes, words: budget.wordCount, lines: budget.lineCount,
            encodedUpperBound: 256 + provider.utf8.count * 6 + budget.logicalBytes * 6 + budget.lineCount * 96 + budget.wordCount * 64)
    }
}

extension PlayerLyricsCandidate {
    func checkedFootprint() throws -> PlayerLyricsFootprint {
        guard id.utf8.count <= 512, title.utf8.count <= 2048, artist.utf8.count <= 2048, album.utf8.count <= 2048 else { throw PlayerLyricsError.responseTooLarge }
        if let duration, !duration.isFinite || duration <= 0 { throw PlayerLyricsError.invalidResponse }
        let document = try lyrics.checkedFootprint()
        let metadata = id.utf8.count + title.utf8.count + artist.utf8.count + album.utf8.count
        return PlayerLyricsFootprint(logicalBytes: document.logicalBytes, words: document.words, lines: document.lines,
            encodedUpperBound: document.encodedUpperBound + metadata * 6 + 256)
    }
}

struct PlayerLyricsCandidateBudget {
    private(set) var logicalBytes = 0
    private(set) var words = 0
    private(set) var lines = 0
    private(set) var encodedUpperBound = 0
    private(set) var count = 0

    var remainingBytes: Int { min(PlayerLyricsLimits.textBytes, PlayerLyricsLimits.candidateTextBytes - logicalBytes) }
    var remainingWords: Int { min(PlayerLyricsLimits.words, PlayerLyricsLimits.candidateWords - words) }

    mutating func admit(_ candidate: PlayerLyricsCandidate) throws {
        let footprint = try candidate.checkedFootprint()
        guard count < PlayerLyricsLimits.candidates,
              footprint.logicalBytes <= PlayerLyricsLimits.candidateTextBytes - logicalBytes,
              footprint.words <= PlayerLyricsLimits.candidateWords - words,
              footprint.lines <= PlayerLyricsLimits.candidateLines - lines,
              footprint.encodedUpperBound <= PlayerLyricsLimits.cacheBytes - encodedUpperBound else { throw PlayerLyricsError.responseTooLarge }
        count += 1
        logicalBytes += footprint.logicalBytes
        words += footprint.words
        lines += footprint.lines
        encodedUpperBound += footprint.encodedUpperBound
    }
}

extension PlayerLyricsTrack {
    func encodedUpperBound() throws -> Int {
        guard resource.utf8.count <= 4096, query.title.utf8.count <= 2048, query.artist.utf8.count <= 2048, query.album.utf8.count <= 2048 else { throw PlayerLyricsError.responseTooLarge }
        return 512 + (resource.utf8.count + query.title.utf8.count + query.artist.utf8.count + query.album.utf8.count) * 6
    }
}
