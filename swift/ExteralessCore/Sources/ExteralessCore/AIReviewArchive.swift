import Foundation

/// Read-only, bounded ZIP/gzip/zlib decoding for the original review tools.
/// No path is opened, extracted to disk, imported or executed by this decoder.
public enum AIReviewArchive {
    public struct Entry: Sendable {
        public let name: String
        public let data: Data
    }
    public static let entryLimit = 8 * 1024 * 1024
    public static let inflatedLimit = 32 * 1024 * 1024

    public static func unpack(_ data: Data, maximumBytes: Int = inflatedLimit) throws -> Data {
        var result = data
        for _ in 0 ..< 3 {
            try Task.checkCancellation()
            let bytes = [UInt8](result)
            if bytes.count >= 18 && bytes[0] == 0x1f && bytes[1] == 0x8b {
                guard bytes[2] == 8, bytes[3] & 0xe0 == 0 else { throw AIError.invalidResponse }
                var start = 10
                let end = bytes.count - 8
                if bytes[3] & 4 != 0 {
                    let length = try little(bytes, start, 2)
                    start += 2 + length
                }
                for mask: UInt8 in [8, 16] where bytes[3] & mask != 0 {
                    while start < end && bytes[start] != 0 { start += 1 }
                    start += 1
                }
                if bytes[3] & 2 != 0 { start += 2 }
                guard start <= end else { throw AIError.invalidResponse }
                let output = try inflate(Data(bytes[start ..< end]), maximumBytes: maximumBytes)
                guard crc32(output) == UInt32(try little(bytes, end, 4)), output.count == (try little(bytes, end + 4, 4)) else { throw AIError.invalidResponse }
                result = output
            } else if bytes.count >= 6 && bytes[0] & 15 == 8 && (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0 {
                guard bytes[1] & 32 == 0 else { throw AIError.invalidResponse }
                let output = try inflate(Data(bytes[2 ..< bytes.count - 4]), maximumBytes: maximumBytes)
                let checksum = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard adler32(output) == checksum else { throw AIError.invalidResponse }
                result = output
            } else { return result }
        }
        return result
    }

    public static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x50, 0x4b, 0x05, 0x06]) }

    public static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw AIError.invalidResponse }
        let minimum = max(0, bytes.count - 65_557)
        var end: Int?
        for index in stride(from: bytes.count - 22, through: minimum, by: -1) {
            if Array(bytes[index ..< index + 4]) == [0x50, 0x4b, 0x05, 0x06] { end = index; break }
        }
        guard let end, try little(bytes, end + 4, 2) == 0, try little(bytes, end + 6, 2) == 0 else { throw AIError.invalidResponse }
        let count = try little(bytes, end + 10, 2)
        guard count <= 500, try little(bytes, end + 8, 2) == count else { throw AIError.inputTooLarge }
        var position = try little(bytes, end + 16, 4)
        let directorySize = try little(bytes, end + 12, 4)
        guard position <= end, directorySize <= end - position else { throw AIError.invalidResponse }
        var output: [Entry] = []
        var names = Set<String>()
        var total = 0
        for _ in 0 ..< count {
            try Task.checkCancellation()
            guard try little(bytes, position, 4) == 0x02014b50 else { throw AIError.invalidResponse }
            let flags = try little(bytes, position + 8, 2)
            let method = try little(bytes, position + 10, 2)
            let checksum = UInt32(try little(bytes, position + 16, 4))
            let compressed = try little(bytes, position + 20, 4)
            let uncompressed = try little(bytes, position + 24, 4)
            let nameLength = try little(bytes, position + 28, 2)
            let extraLength = try little(bytes, position + 30, 2)
            let commentLength = try little(bytes, position + 32, 2)
            let local = try little(bytes, position + 42, 4)
            guard flags & 1 == 0, [0, 8].contains(method), nameLength > 0, nameLength <= 1024,
                  position + 46 <= bytes.count, nameLength <= bytes.count - position - 46,
                  uncompressed <= entryLimit, compressed <= data.count else { throw AIError.inputTooLarge }
            guard let name = String(bytes: bytes[position + 46 ..< position + 46 + nameLength], encoding: .utf8),
                  !name.contains("\0"), !name.hasPrefix("/"), !name.contains("\\"),
                  !name.split(separator: "/").contains(".."), names.insert(name).inserted else { throw AIError.invalidResponse }
            position += 46 + nameLength + extraLength + commentLength
            guard position <= end, try little(bytes, local, 4) == 0x04034b50 else { throw AIError.invalidResponse }
            let localNameLength = try little(bytes, local + 26, 2)
            let localExtraLength = try little(bytes, local + 28, 2)
            let start = local + 30 + localNameLength + localExtraLength
            guard start <= bytes.count, compressed <= bytes.count - start else { throw AIError.invalidResponse }
            if name.hasSuffix("/") { continue }
            let compressedData = Data(bytes[start ..< start + compressed])
            let value: Data; if method == 0 { value = compressedData } else { value = try inflate(compressedData, maximumBytes: min(entryLimit, uncompressed)) }
            guard value.count == uncompressed, crc32(value) == checksum else { throw AIError.invalidResponse }
            total += value.count
            guard total <= inflatedLimit else { throw AIError.inputTooLarge }
            output.append(Entry(name: name, data: value))
        }
        return output
    }

    private static func little(_ bytes: [UInt8], _ position: Int, _ length: Int) throws -> Int {
        guard position >= 0, position <= bytes.count, length <= bytes.count - position else { throw AIError.invalidResponse }
        return (0 ..< length).reduce(0) { $0 | Int(bytes[position + $1]) << ($1 * 8) }
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { value in
        var crc = UInt32(value)
        for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        return crc
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }

    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= 16, offset <= bytes.count * 8, count <= bytes.count * 8 - offset else { throw AIError.invalidResponse }
            var value = 0
            for bit in 0 ..< count { value |= Int((bytes[offset / 8] >> (offset % 8)) & 1) << bit; offset += 1 }
            return value
        }
        mutating func align() { offset = (offset + 7) / 8 * 8 }
    }

    private struct Huffman {
        let symbols: [Int: Int]
        let maximum: Int
        init(_ lengths: [Int]) throws {
            guard lengths.allSatisfy({ (0 ... 15).contains($0) }) else { throw AIError.invalidResponse }
            let maximum = lengths.max() ?? 0
            guard maximum > 0 else { throw AIError.invalidResponse }
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[length] += 1 }
            var remaining = 1
            for length in 1 ... 15 {
                remaining = remaining * 2 - counts[length]
                guard remaining >= 0 else { throw AIError.invalidResponse }
            }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1 ... 15 { code = (code + counts[length - 1]) << 1; next[length] = code }
            var symbols: [Int: Int] = [:]
            for (symbol, length) in lengths.enumerated() where length > 0 {
                var reversed = 0
                let value = next[length]
                for bit in 0 ..< length { reversed = reversed << 1 | (value >> bit & 1) }
                symbols[(1 << length) | reversed] = symbol
                next[length] += 1
            }
            self.symbols = symbols
            self.maximum = maximum
        }
        func decode(_ bits: inout Bits) throws -> Int {
            var value = 0
            for length in 1 ... maximum {
                value |= try bits.read(1) << (length - 1)
                if let symbol = symbols[(1 << length) | value] { return symbol }
            }
            throw AIError.invalidResponse
        }
    }

    private static func inflate(_ data: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= inflatedLimit else { throw AIError.inputTooLarge }
        var bits = Bits(bytes: [UInt8](data))
        var output: [UInt8] = []
        let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let distanceBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        let distanceExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
        var blocks = 0
        while true {
            try Task.checkCancellation()
            blocks += 1
            guard blocks <= 65_536 else { throw AIError.inputTooLarge }
            let final = try bits.read(1)
            let kind = try bits.read(2)
            if kind == 0 {
                bits.align()
                let length = try bits.read(16)
                let inverse = try bits.read(16)
                guard length ^ inverse == 0xffff, output.count + length <= maximumBytes else { throw AIError.inputTooLarge }
                for _ in 0 ..< length { output.append(UInt8(try bits.read(8))) }
            } else {
                guard kind == 1 || kind == 2 else { throw AIError.invalidResponse }
                let literal: Huffman
                let distance: Huffman
                let hasDistanceCodes: Bool
                if kind == 1 {
                    literal = try Huffman((0 ... 287).map { $0 <= 143 ? 8 : ($0 <= 255 ? 9 : ($0 <= 279 ? 7 : 8)) })
                    distance = try Huffman([Int](repeating: 5, count: 32))
                    hasDistanceCodes = true
                } else {
                    let literals = try bits.read(5) + 257
                    let distances = try bits.read(5) + 1
                    let codeCount = try bits.read(4) + 4
                    // RFC 1951 code-length alphabet order (explicit to avoid any
                    // dependency on archive/JVM libraries).
                    let canonicalOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                    guard literals <= 286 else { throw AIError.invalidResponse }
                    var codeLengths = [Int](repeating: 0, count: 19)
                    for i in 0 ..< codeCount { codeLengths[canonicalOrder[i]] = try bits.read(3) }
                    let codeTree = try Huffman(codeLengths)
                    var lengths: [Int] = []
                    while lengths.count < literals + distances {
                        let value = try codeTree.decode(&bits)
                        if value < 16 { lengths.append(value) }
                        else {
                            let count: Int
                            let repeated: Int
                            switch value {
                            case 16:
                                guard let last = lengths.last else { throw AIError.invalidResponse }
                                count = try bits.read(2) + 3; repeated = last
                            case 17: count = try bits.read(3) + 3; repeated = 0
                            case 18: count = try bits.read(7) + 11; repeated = 0
                            default: throw AIError.invalidResponse
                            }
                            guard lengths.count + count <= literals + distances else { throw AIError.invalidResponse }
                            lengths += [Int](repeating: repeated, count: count)
                        }
                    }
                    guard lengths[256] != 0 else { throw AIError.invalidResponse }
                    literal = try Huffman(Array(lengths.prefix(literals)))
                    let distanceLengths = Array(lengths.suffix(distances))
                    hasDistanceCodes = !distanceLengths.allSatisfy { $0 == 0 }
                    distance = try Huffman(hasDistanceCodes ? distanceLengths : [1])
                }
                var operations = 0
                while true {
                    operations += 1
                    if operations % 1024 == 0 { try Task.checkCancellation() }
                    let symbol = try literal.decode(&bits)
                    if symbol < 256 {
                        guard output.count < maximumBytes else { throw AIError.inputTooLarge }
                        output.append(UInt8(symbol))
                    } else if symbol == 256 { break }
                    else {
                        let index = symbol - 257
                        guard hasDistanceCodes, lengthBase.indices.contains(index) else { throw AIError.invalidResponse }
                        let length = lengthBase[index] + (try bits.read(lengthExtra[index]))
                        let d = try distance.decode(&bits)
                        guard distanceBase.indices.contains(d) else { throw AIError.invalidResponse }
                        let offset = distanceBase[d] + (try bits.read(distanceExtra[d]))
                        guard offset <= output.count, output.count + length <= maximumBytes else { throw AIError.inputTooLarge }
                        for _ in 0 ..< length { output.append(output[output.count - offset]) }
                    }
                }
            }
            if final == 1 { return Data(output) }
        }
    }
}
