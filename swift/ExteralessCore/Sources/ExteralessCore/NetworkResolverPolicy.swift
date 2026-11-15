import Foundation

public enum NetworkResolverError: String, Error, Sendable {
    case invalidHostname, invalidEndpoint, tooManyEndpoints, invalidConfiguration
    case malformedResponse, mismatchedResponse, truncatedResponse, unsupportedResponse
    case responseTooLarge, httpStatus, contentType, redirect, transport, timeout
    case noRecords, nameNotFound, cnameLoop, overloaded, configurationChanged, cancelled
}

public enum NetworkDNSRecordType: UInt16, Hashable, Sendable {
    case a = 1, cname = 5, soa = 6, txt = 16, aaaa = 28
}

public struct NetworkDNSQuestion: Hashable, Sendable {
    public let name: String
    public let type: NetworkDNSRecordType

    public init(name: String, type: NetworkDNSRecordType) throws {
        self.name = try Self.canonicalName(name)
        self.type = type
    }

    public static func canonicalName(_ value: String) throws -> String {
        var value = value.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.utf8.count <= 253 else { throw NetworkResolverError.invalidHostname }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
        }) else { throw NetworkResolverError.invalidHostname }
        return value
    }

    /// mDNS, localhost and single-label names belong to the native resolver.
    /// No invented loopback proxy or .svc protocol is used.
    public var isLocalName: Bool {
        return !name.contains(".") || name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local")
    }
}

public struct NetworkIPAddress: Hashable, Sendable {
    public enum Family: Int, Sendable { case ipv4 = 4, ipv6 = 6 }
    public let bytes: [UInt8]
    public let scope: String?
    public var family: Family { bytes.count == 4 ? .ipv4 : .ipv6 }

    public init?(bytes: [UInt8], scope: String? = nil) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        if let scope {
            guard bytes.count == 16, !scope.isEmpty, scope.utf8.count <= 32,
                  scope.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
        }
        self.bytes = bytes
        self.scope = scope
    }

    public init?(_ literal: String) {
        var text = literal
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        let scoped = text.split(separator: "%", omittingEmptySubsequences: false)
        guard scoped.count <= 2 else { return nil }
        text = String(scoped[0])
        let scope = scoped.count == 2 ? String(scoped[1]) : nil
        if !text.contains(":") {
            guard scope == nil, let bytes = Self.ipv4(text) else { return nil }
            self.init(bytes: bytes)
            return
        }
        // Expand the optional dotted IPv4 tail before handling ::.
        if text.contains(".") {
            guard let colon = text.lastIndex(of: ":"), let tail = Self.ipv4(String(text[text.index(after: colon)...])) else { return nil }
            text = String(text[...colon]) + String(UInt16(tail[0]) << 8 | UInt16(tail[1]), radix: 16) + ":" + String(UInt16(tail[2]) << 8 | UInt16(tail[3]), radix: 16)
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func words(_ half: String) -> [UInt16]? {
            if half.isEmpty { return [] }
            var result: [UInt16] = []
            for word in half.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(word.utf8.count), word.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let value = UInt16(word, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }
        guard let left = words(halves[0]), let right = words(halves.count == 2 ? halves[1] : "") else { return nil }
        let count = left.count + right.count
        guard halves.count == 2 ? count < 8 : count == 8 else { return nil }
        let expanded = left + Array(repeating: UInt16(0), count: 8 - count) + right
        self.init(bytes: expanded.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }, scope: scope)
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), (part.count == 1 || part.first != "0"), part.utf8.allSatisfy({ (48...57).contains($0) }), let byte = UInt8(part) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    public var string: String {
        if family == .ipv4 { return bytes.map(String.init).joined(separator: ".") }
        let words = stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
        // An expanded literal is unambiguous to getaddrinfo / NWEndpoint and avoids
        // accidental compression of more than one zero run.
        return words.joined(separator: ":") + (scope.map { "%" + $0 } ?? "")
    }
}

public struct NetworkResolverRoute: Equatable, Sendable {
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let isKnown: Bool
    public init(supportsIPv4: Bool, supportsIPv6: Bool, isKnown: Bool = true) {
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.isKnown = isKnown
    }
    public static let unknown = Self(supportsIPv4: true, supportsIPv6: true, isKnown: false)

    public func prefersIPv6(userPreference: Bool) -> Bool {
        return supportsIPv6 && (!supportsIPv4 || userPreference)
    }

    public func ordered(_ addresses: [NetworkIPAddress], preferIPv6: Bool) -> [NetworkIPAddress] {
        var seen = Set<NetworkIPAddress>()
        let unique = addresses.filter { seen.insert($0).inserted }
        var v4 = unique.filter { $0.family == .ipv4 }
        var v6 = unique.filter { $0.family == .ipv6 }
        // Keep an opposite-family fallback: a proxy/loopback interface can differ
        // from NWPathMonitor's default path. The native connection reports failure.
        let firstIPv6 = prefersIPv6(userPreference: preferIPv6)
        var result: [NetworkIPAddress] = []
        while !v4.isEmpty || !v6.isEmpty {
            if firstIPv6 {
                if !v6.isEmpty { result.append(v6.removeFirst()) }
                if !v4.isEmpty { result.append(v4.removeFirst()) }
            } else {
                if !v4.isEmpty { result.append(v4.removeFirst()) }
                if !v6.isEmpty { result.append(v6.removeFirst()) }
            }
        }
        return Array(result.prefix(16))
    }
}

public struct NetworkDoHEndpoint: Hashable, Sendable {
    public enum Format: Hashable, Sendable { case wirePost, wireGet, jsonGet }
    public let url: URL
    public let format: Format

    public init(_ input: String) throws {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var format = Format.wirePost
        for template in ["{?dns}", "{&dns}"] where input.hasSuffix(template) {
            input = String(input.dropLast(template.count))
            format = .wireGet
        }
        guard input.utf8.count <= 2048, !input.contains("{"), !input.contains("}"),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: input), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw NetworkResolverError.invalidEndpoint }
        let loweredHost = host.lowercased()
        if (loweredHost == "dns.google" || loweredHost == "dns.google.com") && components.path == "/resolve" || loweredHost == "mozilla.cloudflare-dns.com" && components.path == "/dns-query" {
            format = .jsonGet
        }
        let reserved = Set(format == .jsonGet ? ["name", "type"] : ["dns"])
        guard !(components.queryItems ?? []).contains(where: { reserved.contains($0.name.lowercased()) }) else { throw NetworkResolverError.invalidEndpoint }
        self.url = url
        self.format = format
    }
}

public struct NetworkResolverConfiguration: Equatable, Sendable {
    public enum Mode: Int, Sendable { case telegram = 0, nagramX = 1, system = 2, customDoH = 3 }
    public let mode: Mode
    public let preferIPv6: Bool
    public let endpoints: [NetworkDoHEndpoint]
    public let emptyCustomUsesDefaults: Bool
    public var usesDoH: Bool { mode == .nagramX || mode == .customDoH }

    // Exact original provider URLs, including literal IPv6 hosts. A pin here is
    // a URL/protocol pin, not a certificate pin or a claim of current availability.
    public static let originalProviderURLs = [
        "https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query",
        "https://8.8.8.8/dns-query", "https://8.8.4.4/dns-query",
        "https://[2606:4700:4700::1001]/dns-query", "https://[2001:4860:4860::8844]/dns-query"
    ]

    public init(mode: Mode, customDoH: String = "", preferIPv6: Bool = false) throws {
        let custom = try Self.customEndpoints(customDoH)
        self.mode = mode
        self.preferIPv6 = preferIPv6
        self.emptyCustomUsesDefaults = mode == .customDoH && custom.isEmpty
        self.endpoints = mode == .customDoH && !custom.isEmpty ? custom : try Self.originalProviderURLs.map(NetworkDoHEndpoint.init)
    }

    public static func customEndpoints(_ text: String) throws -> [NetworkDoHEndpoint] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard text.utf8.count <= 16_384 else { throw NetworkResolverError.tooManyEndpoints }
        let components = text.components(separatedBy: ",")
        guard components.count <= 8 else { throw NetworkResolverError.tooManyEndpoints }
        var seen = Set<NetworkDoHEndpoint>()
        return try components.map(NetworkDoHEndpoint.init).filter { seen.insert($0).inserted }
    }

    public static func current(settings: ClientSettings = .shared) throws -> Self {
        let snapshot = settings.readSnapshot()
        let raw = snapshot.values["network.dnsType"] ?? .integer(0)
        guard case let .integer(id) = raw, let exact = Int(exactly: id), let mode = Mode(rawValue: exact) else { throw NetworkResolverError.invalidConfiguration }
        let prefer = snapshot.values["network.useIPv6"] == .bool(true)
        // Secret snapshots are intentionally redacted. A missing/unreadable
        // secret is distinct from an explicitly stored/default empty URL list.
        let custom: String
        if mode == .customDoH {
            guard snapshot.lastError == nil, case let .string(value)? = settings.value("network.customDoH") else {
                throw NetworkResolverError.invalidConfiguration
            }
            custom = value
        } else { custom = "" }
        return try Self(mode: mode, customDoH: custom, preferIPv6: prefer)
    }
}
