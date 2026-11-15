import Foundation

/// Injectable lower limits for offline adversarial fixtures. Production maxima
/// bound retained bytes AND object counts, including intermediate source indexes.
public struct AIPluginReviewLimits: Sendable {
    public var maximumInputBytes: Int
    public var maximumInflatedBytes: Int
    public var maximumEntryBytes: Int
    public var maximumEntries: Int
    public var maximumLineIndexEntries: Int
    public var maximumBlobCount: Int
    public var maximumBlobCandidates: Int
    public var maximumBlobBytes: Int
    public var maximumExcerptBytes: Int

    public init(maximumInputBytes: Int = 16 * 1024 * 1024, maximumInflatedBytes: Int = 32 * 1024 * 1024,
                maximumEntryBytes: Int = 8 * 1024 * 1024, maximumEntries: Int = 500,
                maximumLineIndexEntries: Int = 4096, maximumBlobCount: Int = 500, maximumBlobCandidates: Int = 500,
                maximumBlobBytes: Int = 16 * 1024 * 1024, maximumExcerptBytes: Int = 48 * 1024) {
        self.maximumInputBytes = maximumInputBytes; self.maximumInflatedBytes = maximumInflatedBytes
        self.maximumEntryBytes = maximumEntryBytes; self.maximumEntries = maximumEntries
        self.maximumLineIndexEntries = maximumLineIndexEntries; self.maximumBlobCount = maximumBlobCount
        self.maximumBlobCandidates = maximumBlobCandidates
        self.maximumBlobBytes = maximumBlobBytes; self.maximumExcerptBytes = maximumExcerptBytes
    }

    func validate() throws {
        for (value, maximum) in [(maximumInputBytes, 16 * 1024 * 1024), (maximumInflatedBytes, AIReviewArchive.inflatedLimit),
                                 (maximumEntryBytes, AIReviewArchive.entryLimit), (maximumEntries, 500),
                                 (maximumLineIndexEntries, 4096), (maximumBlobCount, 500), (maximumBlobCandidates, 500),
                                 (maximumBlobBytes, 16 * 1024 * 1024), (maximumExcerptBytes, 48 * 1024)] {
            guard value >= 0, value <= maximum else { throw AIError.configuration }
        }
    }
}

public enum AIPluginReviewMode: Equatable, Sendable { case tools, sourceExcerpt }

/// Counts only, never source or decoded payloads. Makes the actual bounded build
/// observable in small fixtures without allocating a production-sized bomb.
public struct AIPluginReviewStatistics: Sendable {
    public internal(set) var processedEntries = 0
    public internal(set) var inflatedBytes = 0
    public internal(set) var sourceFiles = 0
    public internal(set) var sourceLines = 0
    public internal(set) var lineIndexEntries = 0
    public internal(set) var blobCount = 0
    public internal(set) var blobBytes = 0
    public internal(set) var blobCandidates = 0
    public internal(set) var blobScanBytes = 0
    public internal(set) var blobLimitReached = false
    public internal(set) var excerptBytes = 0
}

/// One immutable UTF-8 buffer, with a globally budgeted sparse line index. There
/// is no [String] per line, including for empty lines. Page reads decode only the
/// requested prefix of each line, even when a line is several megabytes long.
struct AIReviewSourceText: Sendable {
    private struct Checkpoint: Sendable { let line: Int; let offset: Int }
    let data: Data
    let lineCount: Int
    let utf16Count: Int
    private let checkpoints: [Checkpoint]
    var indexEntryCount: Int { checkpoints.count }

    init?(data: Data, maximumIndexEntries: Int, checkCancellation: () throws -> Void) throws {
        guard Self.hasTextPrefix(data) else { return nil }
        var checkpoints: [Checkpoint] = []
        let spacing = max(1, data.count / (maximumIndexEntries + 1) + 1)
        var nextOffset = spacing
        var lines = 1
        var utf16 = 0
        let valid = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var pending = 0
            var lower: UInt8 = 0x80
            var upper: UInt8 = 0xbf
            for index in 0 ..< bytes.count {
                if index % 4096 == 0 { try checkCancellation() }
                let byte = bytes[index]
                if pending > 0 {
                    guard byte >= lower, byte <= upper else { return false }
                    pending -= 1; lower = 0x80; upper = 0xbf
                } else {
                    switch byte {
                    case 0 ... 0x7f: utf16 += 1
                    case 0xc2 ... 0xdf: pending = 1; utf16 += 1
                    case 0xe0: pending = 2; lower = 0xa0; utf16 += 1
                    case 0xe1 ... 0xec, 0xee ... 0xef: pending = 2; utf16 += 1
                    case 0xed: pending = 2; upper = 0x9f; utf16 += 1
                    case 0xf0: pending = 3; lower = 0x90; utf16 += 2
                    case 0xf1 ... 0xf3: pending = 3; utf16 += 2
                    case 0xf4: pending = 3; upper = 0x8f; utf16 += 2
                    default: return false
                    }
                }
                if byte == 10 {
                    lines += 1
                    if index + 1 >= nextOffset, checkpoints.count < maximumIndexEntries {
                        checkpoints.append(Checkpoint(line: lines, offset: index + 1))
                        nextOffset = index + 1 + spacing
                    }
                }
            }
            return pending == 0
        }
        guard valid else { return nil }
        self.data = data; self.lineCount = lines; self.utf16Count = utf16; self.checkpoints = checkpoints
    }

    static func hasTextPrefix(_ data: Data) -> Bool {
        var controls = 0
        let sample = data.prefix(8192)
        for byte in sample {
            if byte == 0 { return false }
            if byte < 32, byte != 9, byte != 10, byte != 13 { controls += 1 }
        }
        return controls * 20 < max(1, sample.count)
    }

    func forEachLine(from startLine: Int = 1, checkCancellation: () throws -> Void = { try Task.checkCancellation() },
                     visit: (Int, Range<Int>) throws -> Bool) throws {
        guard startLine >= 1, startLine <= lineCount else { return }
        var low = 0, high = checkpoints.count
        while low < high {
            let mid = (low + high) / 2
            if checkpoints[mid].line <= startLine { low = mid + 1 } else { high = mid }
        }
        var line = low == 0 ? 1 : checkpoints[low - 1].line
        var offset = low == 0 ? 0 : checkpoints[low - 1].offset
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            while line < startLine, offset < bytes.count {
                if offset % 4096 == 0 { try checkCancellation() }
                if bytes[offset] == 10 { line += 1 }
                offset += 1
            }
            var start = offset
            while offset < bytes.count {
                if offset % 4096 == 0 { try checkCancellation() }
                if bytes[offset] == 10 {
                    if try !visit(line, start ..< offset) { return }
                    line += 1; start = offset + 1
                }
                offset += 1
            }
            _ = try visit(line, start ..< offset)
        }
    }

    func linePrefix(_ range: Range<Int>, maximumUTF16: Int) -> (String, Bool) {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var end = range.lowerBound, length = 0
            while end < range.upperBound {
                let width = Self.scalarWidth(bytes[end])
                let units = width == 4 ? 2 : 1
                if length + units > maximumUTF16 { break }
                length += units; end += width
            }
            return (String(decoding: bytes[range.lowerBound ..< end], as: UTF8.self), end < range.upperBound)
        }
    }

    func page(offset: Int, maximumUTF16: Int) throws -> (text: String, start: Int, end: Int) {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var byte = 0, units = 0
            var nextCheck = 0
            while byte < bytes.count, units < offset {
                if byte >= nextCheck { try Task.checkCancellation(); nextCheck = byte + 4096 }
                let width = Self.scalarWidth(bytes[byte]); byte += width; units += width == 4 ? 2 : 1
            }
            let start = byte, startUnits = units
            while byte < bytes.count {
                if byte >= nextCheck { try Task.checkCancellation(); nextCheck = byte + 4096 }
                let width = Self.scalarWidth(bytes[byte]), size = width == 4 ? 2 : 1
                if units - startUnits + size > maximumUTF16 { break }
                byte += width; units += size
            }
            return (String(decoding: bytes[start ..< byte], as: UTF8.self), startUnits, units)
        }
    }

    private static func scalarWidth(_ byte: UInt8) -> Int {
        byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4
    }
}

struct AIReviewBoundedText {
    let maximumBytes: Int
    private(set) var data = Data()
    private var truncated = false
    var remaining: Int { maximumBytes - data.count }
    var isFull: Bool { remaining == 0 || truncated }
    var text: String { String(decoding: data, as: UTF8.self) }

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func append(_ text: String) {
        guard !isFull else { return }
        let utf8 = text.utf8
        if utf8.count > remaining { truncated = true }
        var end = utf8.index(utf8.startIndex, offsetBy: min(remaining, utf8.count))
        while end != utf8.endIndex, end > utf8.startIndex, utf8[end] & 0xc0 == 0x80 { end = utf8.index(before: end) }
        data.append(contentsOf: utf8[..<end])
    }
    mutating func append(_ source: AIReviewSourceText) {
        guard !isFull else { return }
        if source.data.count > remaining { truncated = true }
        source.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var end = min(remaining, bytes.count)
            while end > 0, end < bytes.count, bytes[end] & 0xc0 == 0x80 { end -= 1 }
            data.append(contentsOf: bytes[..<end])
        }
    }
}

struct AIReviewBlob: Sendable { let origin: String; let data: Data }

private struct AIReviewBlobCollector {
    let limits: AIPluginReviewLimits
    var blobs: [AIReviewBlob] = []
    var bytes = 0
    var candidates = 0
    var scanned = 0
    var stopped = false
    private var remaining: Int { limits.maximumBlobBytes - bytes }
    private var encodedLimit: Int { (remaining + 2) / 3 * 4 }

    mutating func binary(_ data: Data, origin: String) {
        guard !stopped else { return }
        guard blobs.count < limits.maximumBlobCount, data.count <= remaining else { stopped = true; return }
        blobs.append(AIReviewBlob(origin: origin, data: data)); bytes += data.count
        if blobs.count == limits.maximumBlobCount || remaining == 0 { stopped = true }
    }

    mutating func scan(_ source: AIReviewSourceText, name: String, checkCancellation: () throws -> Void) throws {
        guard !stopped else { return }
        guard blobs.count < limits.maximumBlobCount, candidates < limits.maximumBlobCandidates, remaining > 0 else { stopped = true; return }
        var block = Data(), blockLine = 0
        try source.forEachLine(checkCancellation: checkCancellation) { line, range in
            try checkCancellation()
            return try source.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                let stripped = try Self.stripped(range, bytes: buffer, checkCancellation: checkCancellation)
                var mixed = 0
                var isBlockLine = stripped.count >= 16
                if isBlockLine {
                    for index in stripped {
                        if index % 4096 == 0 { try checkCancellation() }
                        scanned += 1
                        let byte = buffer[index]
                        if !Self.isBase64(byte), byte != 61 { isBlockLine = false; break }
                        mixed |= Self.letterKinds(byte)
                        if index - stripped.lowerBound >= encodedLimit { stopped = true; return false }
                    }
                    isBlockLine = isBlockLine && mixed == 7
                }
                if isBlockLine {
                    guard stripped.count <= encodedLimit - block.count else { stopped = true; return false }
                    if block.isEmpty { blockLine = line }
                    block.append(contentsOf: buffer[stripped])
                    return true
                }
                if !block.isEmpty {
                    if block.count >= 200 { try appendBase64(block, origin: "\(name):\(blockLine)", checkCancellation: checkCancellation) }
                    // Reuse one bounded buffer for tiny non-candidate blocks too;
                    // alternating short lines must not allocate an origin String
                    // and fresh buffer millions of times before any blob is found.
                    block.removeAll(keepingCapacity: true)
                    if stopped { return false }
                }
                var index = range.lowerBound
                while index < range.upperBound {
                    if index % 4096 == 0 { try checkCancellation() }
                    scanned += 1
                    if !Self.isBase64(buffer[index]) { index += 1; continue }
                    let start = index
                    mixed = 0
                    while index < range.upperBound, Self.isBase64(buffer[index]) {
                        if index % 4096 == 0 { try checkCancellation() }
                        scanned += 1; mixed |= Self.letterKinds(buffer[index]); index += 1
                        if index - start > encodedLimit { stopped = true; return false }
                    }
                    var padding = 0
                    while index < range.upperBound, buffer[index] == 61, padding < 2 { padding += 1; index += 1 }
                    if index - start >= 200, mixed == 7 {
                        // Candidate count and expected decoded bytes are checked
                        // before creating either its encoded copy or decoded Data.
                        let decodedBytes = (index - start - padding) * 6 / 8
                        guard decodedBytes <= remaining, blobs.count < limits.maximumBlobCount else { stopped = true; return false }
                        try appendBase64(Data(buffer[start ..< index]), origin: "\(name):\(line)", checkCancellation: checkCancellation)
                        if stopped { return false }
                    }
                }
                return true
            }
        }
        if !stopped, block.count >= 200 { try appendBase64(block, origin: "\(name):\(blockLine)", checkCancellation: checkCancellation) }
    }

    private mutating func appendBase64(_ encoded: Data, origin: String, checkCancellation: () throws -> Void) throws {
        guard encoded.count >= 200 else { return }
        guard candidates < limits.maximumBlobCandidates else { stopped = true; return }
        candidates += 1
        defer { if candidates >= limits.maximumBlobCandidates { stopped = true } }
        guard let data = try AIReviewBase64.decode(encoded, maximumBytes: remaining, checkCancellation: checkCancellation), !data.isEmpty else { return }
        binary(data, origin: origin)
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 43 || byte == 47 || byte == 95 || byte == 45
    }
    private static func letterKinds(_ byte: UInt8) -> Int {
        (65 ... 90).contains(byte) ? 1 : (97 ... 122).contains(byte) ? 2 : (48 ... 57).contains(byte) ? 4 : 0
    }
    private static func stripped(_ range: Range<Int>, bytes: UnsafeRawBufferPointer, checkCancellation: () throws -> Void) throws -> Range<Int> {
        var start = range.lowerBound, end = range.upperBound
        var nextCheck = start
        func space(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 13 }
        while start < end {
            if start >= nextCheck { try checkCancellation(); nextCheck = start + 4096 }
            if space(bytes[start]) || bytes[start] == 35 { start += 1 }
            else if bytes[start] == 47, start + 1 < end, bytes[start + 1] == 47 { start += 2 }
            else { break }
        }
        if start + 1 < end, bytes[start] == 98 || bytes[start] == 114, bytes[start + 1] == 34 || bytes[start + 1] == 39 { start += 1 }
        func trim(_ byte: UInt8) -> Bool {
            switch byte { case 32, 9, 13, 39, 34, 40, 41, 43, 44, 92: return true; default: return false }
        }
        while start < end, trim(bytes[start]) { if start % 4096 == 0 { try checkCancellation() }; start += 1 }
        while end > start, trim(bytes[end - 1]) { if end % 4096 == 0 { try checkCancellation() }; end -= 1 }
        return start ..< end
    }
}

enum AIReviewBase64 {
    static func decode(_ data: Data, maximumBytes: Int, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes <= AIPluginReviewTools.maximumFileBytes,
              data.count <= (maximumBytes + 2) / 3 * 4 + 8 else { return nil }
        var compact = Data()
        for (index, byte) in data.enumerated() {
            if index % 4096 == 0 { try checkCancellation() }
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            compact.append(byte == 45 ? 43 : byte == 95 ? 47 : byte)
        }
        let unpadded = compact.count - compact.suffix(2).reversed().prefix(while: { $0 == 61 }).count
        guard unpadded * 6 / 8 <= maximumBytes, compact.count % 4 != 1 else { return nil }
        compact.append(contentsOf: repeatElement(UInt8(61), count: (4 - compact.count % 4) % 4))
        try checkCancellation()
        guard let decoded = Data(base64Encoded: compact), decoded.count <= maximumBytes else { return nil }
        try checkCancellation()
        return decoded
    }
}

struct AIReviewSourceContext {
    var files: [(name: String, text: AIReviewSourceText)] = []
    var blobs: [AIReviewBlob] = []
    var excerpt = ""
    var statistics = AIPluginReviewStatistics()

    static func build(snapshot: AIPluginReviewSnapshot, mode: AIPluginReviewMode, limits: AIPluginReviewLimits,
                      checkCancellation: () throws -> Void) throws -> AIReviewSourceContext {
        try limits.validate()
        try checkCancellation()
        guard snapshot.files.count <= limits.maximumEntries else { throw AIError.inputTooLarge }
        var inputBytes = 0
        for file in snapshot.files {
            guard file.data.count <= limits.maximumInputBytes - inputBytes else { throw AIError.inputTooLarge }
            inputBytes += file.data.count
        }
        var result = AIReviewSourceContext()
        var excerpt = AIReviewBoundedText(maximumBytes: limits.maximumExcerptBytes)
        var collector = AIReviewBlobCollector(limits: limits)
        var seen = Set<String>()
        func consume(name: String, data: Data) throws -> Bool {
            try checkCancellation()
            guard result.statistics.processedEntries < limits.maximumEntries,
                  data.count <= limits.maximumInflatedBytes - result.statistics.inflatedBytes else { throw AIError.inputTooLarge }
            guard seen.insert(name).inserted else { throw AIError.configuration }
            result.statistics.processedEntries += 1
            result.statistics.inflatedBytes += data.count
            let indexBudget = mode == .tools ? limits.maximumLineIndexEntries - result.statistics.lineIndexEntries : 0
            if let text = try AIReviewSourceText(data: data, maximumIndexEntries: indexBudget, checkCancellation: checkCancellation) {
                result.statistics.sourceFiles += 1
                result.statistics.sourceLines += text.lineCount
                result.statistics.lineIndexEntries += text.indexEntryCount
                if !excerpt.isFull { excerpt.append("\n--- \(name) ---\n"); excerpt.append(text) }
                if mode == .tools {
                    result.files.append((name, text))
                    try collector.scan(text, name: name, checkCancellation: checkCancellation)
                }
            } else if mode == .tools { collector.binary(data, origin: name) }
            return mode == .tools || !excerpt.isFull
        }
        for file in snapshot.files {
            try checkCancellation()
            guard !file.name.isEmpty, file.name.utf8.count <= 1024, !file.name.contains("\0"), !file.name.hasPrefix("/"),
                  !file.name.contains("\\"), !file.name.split(separator: "/").contains("..") else { throw AIError.configuration }
            if AIReviewArchive.isZip(file.data) {
                try AIReviewArchive.forEachEntry(file.data, maximumBytes: limits.maximumInflatedBytes - result.statistics.inflatedBytes,
                    maximumEntries: limits.maximumEntries - result.statistics.processedEntries, maximumEntryBytes: limits.maximumEntryBytes,
                    checkCancellation: checkCancellation) { try consume(name: $0.name, data: $0.data) }
            } else { _ = try consume(name: file.name, data: file.data) }
            if mode == .sourceExcerpt, excerpt.isFull { break }
        }
        result.blobs = collector.blobs
        result.excerpt = excerpt.text
        result.statistics.blobCount = collector.blobs.count
        result.statistics.blobBytes = collector.bytes
        result.statistics.blobCandidates = collector.candidates
        result.statistics.blobScanBytes = collector.scanned
        result.statistics.blobLimitReached = collector.stopped
        result.statistics.excerptBytes = excerpt.data.count
        guard result.statistics.sourceFiles > 0 || !result.blobs.isEmpty || (mode == .sourceExcerpt && result.statistics.processedEntries > 0) else { throw AIError.emptyResponse }
        return result
    }
}
