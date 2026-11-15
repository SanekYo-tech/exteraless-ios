import Foundation

public struct NetworkDNSRecord: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case address(NetworkIPAddress), cname(String), text([Data]), soa(minimum: UInt32)
    }
    public let name: String
    public let ttl: UInt32
    public let value: Value
    public init(name: String, ttl: UInt32, value: Value) { self.name = name; self.ttl = ttl; self.value = value }
}

public struct NetworkDNSAnswer: Equatable, Sendable {
    public let records: [NetworkDNSRecord]
    public let canonicalName: String
    public let ttl: TimeInterval
    public let negative: NetworkResolverError?

    public init(records: [NetworkDNSRecord], canonicalName: String, ttl: TimeInterval, negative: NetworkResolverError? = nil) {
        self.records = records; self.canonicalName = canonicalName; self.ttl = max(0, min(3600, ttl)); self.negative = negative
    }

    public var addresses: [NetworkIPAddress] { records.compactMap { if case let .address(ip) = $0.value { return ip }; return nil } }
    public var texts: [Data] { records.compactMap { if case let .text(parts) = $0.value { return parts.reduce(into: Data()) { $0.append($1) } }; return nil } }

    /// Follow only answer-section records rooted at the exact question. Additional
    /// A/AAAA records are never trusted as answers. This also pins a CNAME's TTL.
    static func select(question: NetworkDNSQuestion, records: [NetworkDNSRecord], authority: [NetworkDNSRecord], rcode: Int) throws -> Self {
        guard rcode == 0 || rcode == 3 else { throw NetworkResolverError.unsupportedResponse }
        var name = question.name
        var seen = Set<String>()
        var ttl = 3600.0
        for _ in 0..<9 {
            guard seen.insert(name).inserted else { throw NetworkResolverError.cnameLoop }
            let matching = records.filter { $0.name == name }
            let values = matching.filter { record in
                switch record.value {
                case let .address(ip): return question.type == (ip.family == .ipv4 ? .a : .aaaa)
                case .text: return question.type == .txt
                default: return false
                }
            }
            let aliases = matching.compactMap { record -> (String, UInt32)? in
                if case let .cname(target) = record.value { return (target, record.ttl) }
                return nil
            }
            guard Set(aliases.map(\.0)).count <= 1, values.isEmpty || aliases.isEmpty else { throw NetworkResolverError.malformedResponse }
            if !values.isEmpty {
                guard rcode == 0 else { throw NetworkResolverError.malformedResponse }
                ttl = min(ttl, Double(values.map(\.ttl).min() ?? 0))
                return Self(records: values, canonicalName: name, ttl: ttl)
            }
            if let alias = aliases.first {
                ttl = min(ttl, Double(aliases.map(\.1).min() ?? 0))
                name = alias.0
                continue
            }
            let negativeTTL = authority.compactMap { record -> Double? in
                guard record.name.isEmpty || name == record.name || name.hasSuffix("." + record.name), case let .soa(minimum) = record.value else { return nil }
                return Double(min(record.ttl, minimum, 60))
            }.min() ?? 0
            if name != question.name && rcode == 0 {
                return Self(records: [], canonicalName: name, ttl: ttl)
            }
            return Self(records: [], canonicalName: name, ttl: min(ttl, negativeTTL), negative: rcode == 3 ? .nameNotFound : .noRecords)
        }
        throw NetworkResolverError.cnameLoop
    }
}

public enum NetworkDNSWire {
    public static let maximumPacketBytes = 65_535
    public static let maximumRecords = 256

    public static func query(_ question: NetworkDNSQuestion, id: UInt16) -> Data {
        var bytes: [UInt8] = []
        func word(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 255)] }
        word(id); word(0x0100); word(1); word(0); word(0); word(1)
        for label in question.name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes += label.utf8 }
        bytes.append(0); word(question.type.rawValue); word(1)
        // EDNS(0), 1232-byte UDP size. No ECS and no DNSSEC-validation claim.
        bytes.append(0); word(41); word(1232); word(0); word(0); word(0)
        return Data(bytes)
    }

    public static func response(_ data: Data, question: NetworkDNSQuestion, id: UInt16) throws -> NetworkDNSAnswer {
        guard (12...maximumPacketBytes).contains(data.count) else { throw NetworkResolverError.malformedResponse }
        var reader = Reader(bytes: Array(data))
        guard try reader.word() == id else { throw NetworkResolverError.mismatchedResponse }
        let flags = try reader.word()
        guard flags & 0x8000 != 0, flags & 0x7800 == 0, flags & 0x0040 == 0 else { throw NetworkResolverError.malformedResponse }
        guard flags & 0x0200 == 0 else { throw NetworkResolverError.truncatedResponse }
        let qd = Int(try reader.word()), an = Int(try reader.word()), ns = Int(try reader.word()), ar = Int(try reader.word())
        guard qd == 1, an + ns + ar <= maximumRecords else { throw NetworkResolverError.malformedResponse }
        guard try reader.name() == question.name, try reader.word() == question.type.rawValue, try reader.word() == 1 else { throw NetworkResolverError.mismatchedResponse }
        var answers: [NetworkDNSRecord] = [], authority: [NetworkDNSRecord] = []
        var hasOPT = false
        for index in 0..<(an + ns + ar) {
            let name = try reader.name()
            let type = try reader.word(), recordClass = try reader.word(), ttl = try reader.dword()
            let length = Int(try reader.word())
            let end = reader.offset + length
            guard end <= reader.bytes.count else { throw NetworkResolverError.malformedResponse }
            var value: NetworkDNSRecord.Value?
            if type == 41 {
                guard index >= an + ns, name.isEmpty, !hasOPT, recordClass >= 512, ttl >> 24 == 0, (ttl >> 16) & 255 == 0 else { throw NetworkResolverError.unsupportedResponse }
                hasOPT = true
                while reader.offset < end {
                    guard reader.offset + 4 <= end else { throw NetworkResolverError.malformedResponse }
                    _ = try reader.word()
                    let size = Int(try reader.word())
                    guard reader.offset + size <= end else { throw NetworkResolverError.malformedResponse }
                    reader.offset += size
                }
            } else if recordClass == 1 {
                switch type {
                case 1, 28:
                    guard length == (type == 1 ? 4 : 16), let ip = NetworkIPAddress(bytes: Array(reader.bytes[reader.offset..<end])) else { throw NetworkResolverError.malformedResponse }
                    value = .address(ip); reader.offset = end
                case 5:
                    let target = try reader.name()
                    guard !target.isEmpty else { throw NetworkResolverError.malformedResponse }
                    value = .cname(target)
                case 16:
                    var parts: [Data] = []
                    while reader.offset < end {
                        let size = Int(reader.bytes[reader.offset]); reader.offset += 1
                        guard reader.offset + size <= end else { throw NetworkResolverError.malformedResponse }
                        parts.append(Data(reader.bytes[reader.offset..<(reader.offset + size)])); reader.offset += size
                    }
                    value = .text(parts)
                case 6:
                    _ = try reader.name(); _ = try reader.name()
                    for _ in 0..<4 { _ = try reader.dword() }
                    value = .soa(minimum: try reader.dword())
                default: reader.offset = end
                }
            } else { reader.offset = end }
            guard reader.offset == end else { throw NetworkResolverError.malformedResponse }
            if let value {
                let record = NetworkDNSRecord(name: name, ttl: ttl, value: value)
                if index < an { answers.append(record) }
                else if index < an + ns { authority.append(record) }
            }
        }
        guard reader.offset == reader.bytes.count else { throw NetworkResolverError.malformedResponse }
        return try NetworkDNSAnswer.select(question: question, records: answers, authority: authority, rcode: Int(flags & 15))
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func word() throws -> UInt16 {
            guard offset + 2 <= bytes.count else { throw NetworkResolverError.malformedResponse }
            defer { offset += 2 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        mutating func dword() throws -> UInt32 { UInt32(try word()) << 16 | UInt32(try word()) }
        mutating func name() throws -> String {
            var at = offset, consumed: Int?, labels: [String] = [], seen = Set<Int>(), count = 1
            for _ in 0..<128 {
                guard at < bytes.count, seen.insert(at).inserted else { throw NetworkResolverError.malformedResponse }
                let length = Int(bytes[at])
                if length == 0 {
                    offset = consumed ?? (at + 1)
                    return labels.joined(separator: ".").lowercased()
                }
                if length & 0xc0 == 0xc0 {
                    guard at + 1 < bytes.count else { throw NetworkResolverError.malformedResponse }
                    let pointer = (length & 63) << 8 | Int(bytes[at + 1])
                    // RFC 1035 pointers refer to a prior occurrence, never forwards.
                    guard pointer >= 12, pointer < at else { throw NetworkResolverError.malformedResponse }
                    if consumed == nil { consumed = at + 2 }
                    at = pointer
                } else {
                    guard length <= 63, at + 1 + length <= bytes.count else { throw NetworkResolverError.malformedResponse }
                    count += length + 1
                    guard count <= 255 else { throw NetworkResolverError.malformedResponse }
                    let label = bytes[(at + 1)..<(at + 1 + length)]
                    guard label.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), let text = String(bytes: label, encoding: .ascii) else { throw NetworkResolverError.malformedResponse }
                    labels.append(text); at += length + 1
                }
            }
            throw NetworkResolverError.malformedResponse
        }
    }
}
