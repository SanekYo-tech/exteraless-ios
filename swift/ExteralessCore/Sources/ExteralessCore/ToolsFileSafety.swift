import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ToolsError: Error, LocalizedError, Equatable, Sendable {
    case invalidArchive(String)
    case unsafePath
    case sizeLimit
    case unavailable(String)
    case http(Int)
    case rateLimited
    case invalidRelease
    case checksumMismatch
    case incompleteDownload
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidArchive(reason): return "Invalid backup: \(reason)"
        case .unsafePath: return "The file path is unsafe or is redirected by a symbolic link."
        case .sizeLimit: return "The file exceeds the size or item limit."
        case let .unavailable(reason): return reason
        case let .http(status): return "GitHub returned HTTP \(status). Please try again later."
        case .rateLimited: return "GitHub's public API rate limit was reached. Please try again later."
        case .invalidRelease: return "The release does not contain a supported iOS IPA asset."
        case .checksumMismatch: return "The SHA-256 checksum does not match. The file was not applied."
        case .incompleteDownload: return "The downloaded file is incomplete or has an unexpected size."
        case .rollbackFailed: return "Recovery needs review. Current state and recovery records have been retained. Open Configuration backup → Review recovery before plugins resume."
        }
    }
}

/// Data-only file operations. No shell, archive extractor, module loader or URL fetch.
public enum ToolsFileSafety {
    public static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 240 && value != "." && value != ".."
            && !value.hasPrefix(".") && !value.hasSuffix(".")
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 95 || $0 == 46
            }
    }

    public static func checkedChild(_ name: String, root: URL) throws -> URL {
        guard root.isFileURL, isComponent(name) else { throw ToolsError.unsafePath }
        let base = try checkedPath(root, directory: true)
        let child = base.appendingPathComponent(name)
        return try checkedPath(child)
    }

    /// Spelling only. Filesystem authority comes from checkedPath / held directory
    /// descriptors, never Foundation's whole-path symlink resolution or URL equality.
    static func canonicalFileURL(_ url: URL) -> URL {
        #if canImport(Darwin)
        for alias in ["/var", "/tmp", "/etc"] where url.path == alias || url.path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: "/private" + url.path, isDirectory: url.hasDirectoryPath)
        }
        #endif
        return url
    }

    static func pathComponents(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.contains("\0") else { throw ToolsError.unsafePath }
        let components = url.path.split(separator: "/").map(String.init)
        // Do not let lexical standardization erase a caller-controlled link before
        // it is checked. FileManager-provided temp/home/container URLs need no dots.
        guard !components.contains("."), !components.contains("..") else { throw ToolsError.unsafePath }
        return components
    }

    /// Readonly validation of every existing component. Missing suffixes are allowed
    /// for prospective app-owned paths; actual I/O reopens/pins them with O_NOFOLLOW.
    static func checkedPath(_ url: URL, directory: Bool = false) throws -> URL {
        #if canImport(Darwin) || canImport(Glibc)
        return try ToolsDirectoryDescriptor.checkedPath(url, directory: directory)
        #else
        throw ToolsError.unavailable("Descriptor-bound file access is unavailable on this platform.")
        #endif
    }

    public static func read(_ url: URL, maximumBytes: Int, hooks: ToolsFileOperationHooks = .init()) throws -> Data {
        guard url.isFileURL, maximumBytes > 0 else { throw ToolsError.unsafePath }
        #if canImport(Darwin) || canImport(Glibc)
        return try ToolsReadDescriptor(url, maximumBytes: Int64(maximumBytes), hooks: hooks).readAll(maximumBytes: maximumBytes, hooks: hooks)
        #else
        throw ToolsError.unavailable("Descriptor-bound file access is unavailable on this platform.")
        #endif
    }

    /// Reject excessive nesting before Foundation's JSON decoder builds any objects.
    public static func checkJSON(_ data: Data, maximumBytes: Int, maximumDepth: Int = 24, maximumSeparators: Int = 100_000) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ToolsError.sizeLimit }
        var depth = 0
        var separators = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 {
                quoted = true
            } else if byte == 44 {
                separators += 1
                guard separators <= maximumSeparators else { throw ToolsError.sizeLimit }
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= maximumDepth else { throw ToolsError.sizeLimit }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { throw ToolsError.invalidArchive("Malformed JSON.") }
            }
        }
        guard depth == 0, !quoted else { throw ToolsError.invalidArchive("Truncated JSON.") }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// CryptoKit in the app; the bounded, dependency-free fallback keeps offline
/// Foundation tests available on Linux. This is an integrity checksum, not encryption.
public struct ToolsSHA256: @unchecked Sendable {
    #if canImport(CryptoKit)
    private var native = CryptoKit.SHA256()
    #else
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0
    #endif

    public init() {}

    public mutating func update(_ data: Data) {
        #if canImport(CryptoKit)
        native.update(data: data)
        #else
        byteCount &+= UInt64(data.count)
        for byte in data {
            pending.append(byte)
            if pending.count == 64 {
                compress(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        #endif
    }

    public func hexDigest() -> String {
        #if canImport(CryptoKit)
        var copy = native
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var copy = self
        let bits = copy.byteCount &* 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 { copy.pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            copy.pending.append(UInt8(truncatingIfNeeded: bits >> shift))
        }
        let blocks = copy.pending
        for start in stride(from: 0, to: blocks.count, by: 64) {
            copy.compress(Array(blocks[start..<(start + 64)]))
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
        #endif
    }

    public static func hex(_ data: Data) -> String {
        var hash = Self()
        hash.update(data)
        return hash.hexDigest()
    }

    #if !canImport(CryptoKit)
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private mutating func compress(_ bytes: [UInt8]) {
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var words = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let p = i * 4
            words[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16
                | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
        }
        for i in 16..<64 {
            let x = words[i - 15], y = words[i - 2]
            let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
            let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
            words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let t1 = h &+ s1 &+ ((e & f) ^ (~e & g)) &+ Self.constants[i] &+ words[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        let result = [a, b, c, d, e, f, g, h]
        for i in 0..<8 { state[i] = state[i] &+ result[i] }
    }
    #endif
}
