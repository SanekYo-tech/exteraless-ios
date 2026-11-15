import Foundation

/// Navigation only. No route carries a setting value or an import/reset command.
public enum ClientSettingsRoute: Equatable, Hashable, Sendable {
    case root
    case search
    case setting(String)
    case row(String)
    case action(String)
    case unavailable(String)
}

public enum ClientSettingsRouteRequest: Equatable, Sendable {
    case canonical(ClientSettingsRoute)
    case original(page: String?, className: String?, row: String?)
}

public enum ClientSettingsRouteError: Error, Equatable, Sendable {
    case invalidLink, ambiguous, notFound, retired, changed, oversizedCatalog
    case unavailable(String)

    public var message: String {
        switch self {
        case .invalidLink: return "This settings link is invalid. Links can open a control, but cannot set a value."
        case .ambiguous: return "This Android settings name identifies more than one destination. Specify its page and row."
        case .notFound: return "This setting has no registered native destination."
        case .retired: return "Reopen settings from the current account."
        case .changed: return "This settings entry changed. Refresh the results and select it again."
        case .oversizedCatalog: return "The settings catalog exceeds the supported limit."
        case let .unavailable(reason): return reason
        }
    }
}

/// A result identifier is a selection capability, not a reusable URL. Its scope
/// and version survive unchanged refreshes and never survive retirement or ABA.
public struct ClientSettingsSearchTicket: Equatable, Hashable, Sendable {
    public let scope: UUID
    public let version: UInt64
    public let identifier: String

    public var storageID: String { "exteraless-result/\(scope.uuidString)/\(version)/\(identifier)" }
}

public struct ClientSettingsSearchAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let section: String
    public let registration: UUID
    public let unavailableReason: String?

    public init(id: String, title: String, section: String, registration: UUID, unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.section = section
        self.registration = registration
        self.unavailableReason = unavailableReason
    }
}

public struct ClientSettingsSearchItem: Equatable, Sendable {
    public let ticket: ClientSettingsSearchTicket
    public let title: String
    public let section: String
    public let explanation: String
    public let terms: [String]
    public let route: ClientSettingsRoute
    public let unavailableReason: String?

    public var isAvailable: Bool { unavailableReason == nil }
    public var link: URL? { ClientSettingsLink.url(for: route) }
}

/// Metadata-only index. In particular, refresh does not accept snapshot.values,
/// credential strings, stored overrides, private account fields or a file reader.
public struct ClientSettingsSearchIndex: Sendable {
    public static let maximumEntries = 2048
    public static let maximumQueryUTF16 = 256
    public static let maximumResults = 80

    private struct Fingerprint: Equatable, Sendable {
        let definition: ClientSettingDefinition?
        let definitionVersion: UUID?
        let action: ClientSettingsSearchAction?
        let route: ClientSettingsRoute
        let title: String
        let section: String
        let explanation: String
        let terms: [String]
        let unavailable: String?
    }
    private struct Record: Sendable {
        let fingerprint: Fingerprint
        let item: ClientSettingsSearchItem
    }

    public let scope: UUID
    public private(set) var isActive = true
    private var sequence: UInt64 = 0
    private var records: [String: Record] = [:]
    private var order: [String] = []

    public init(scope: UUID = UUID()) { self.scope = scope }

    /// This is also the shipping Root's filter, via the coordinator hunk.
    public static func isGenericVisible(_ definition: ClientSettingDefinition) -> Bool {
        definition.section != "AI state"
            && !ClientAPIFeatures.requiresNativeEditor(definition.key)
            && !ExteraConfigCompatibility.keys.contains(definition.key)
            && !definition.key.hasPrefix(ExteraConfigCompatibility.prefix)
    }

    public var items: [ClientSettingsSearchItem] {
        isActive ? order.compactMap { records[$0]?.item } : []
    }

    public mutating func retire() {
        isActive = false
        records.removeAll()
        order.removeAll()
    }

    /// Publication is all-or-nothing. A failed refresh invalidates old tickets;
    /// the caller cannot continue navigating a plausible but stale catalog.
    /// Store-backed callers pass snapshot.definitionVersions so an unobserved
    /// intermediate schema publication still invalidates its retained selections.
    public mutating func refresh(definitions: [ClientSettingDefinition], secretKeys: Set<String>,
                                 actions: [ClientSettingsSearchAction],
                                 definitionVersions: [String: UUID] = [:],
                                 localize: (String, String) -> String = { _, fallback in fallback }) throws {
        guard isActive else { throw ClientSettingsRouteError.retired }
        do {
            guard definitions.count + actions.count <= Self.maximumEntries else { throw ClientSettingsRouteError.oversizedCatalog }
            var byAction: [String: ClientSettingsSearchAction] = [:]
            for action in actions {
                guard ClientSettingDefinition.isValidKey(action.id), byAction[action.id] == nil else { throw ClientSettingsRouteError.ambiguous }
                guard Self.bounded(action.title, bytes: 2048), Self.bounded(action.section, bytes: 512),
                      Self.bounded(action.unavailableReason ?? "", bytes: 8192) else { throw ClientSettingsRouteError.oversizedCatalog }
                byAction[action.id] = action
            }
            var next: [String: Record] = [:]
            var nextOrder: [String] = []
            let previousRecords = records
            let scope = self.scope
            var nextSequence = sequence
            func clipped(_ value: String, limit: Int = 2048) -> String { String(decoding: value.utf8.prefix(limit), as: UTF8.self) }
            func localized(_ key: String, _ fallback: String) -> String { clipped(localize(key, fallback)) }
            func append(_ id: String, definition: ClientSettingDefinition? = nil, action: ClientSettingsSearchAction? = nil,
                        route: ClientSettingsRoute, title: String, section: String, explanation: String = "", unavailable: String? = nil) throws {
                guard next[id] == nil else { throw ClientSettingsRouteError.ambiguous }
                let aliases = ClientSettingsSourceRoutes.aliases(for: route)
                let terms = Array(([id] + aliases).prefix(64)).map { clipped($0, limit: 256) }
                let fingerprint = Fingerprint(definition: definition,
                    definitionVersion: definition.flatMap { definitionVersions[$0.key] }, action: action, route: route, title: title,
                    section: section, explanation: explanation, terms: terms, unavailable: unavailable)
                let version: UInt64
                if let previous = previousRecords[id], previous.fingerprint == fingerprint {
                    version = previous.item.ticket.version
                } else {
                    guard nextSequence < UInt64.max else { throw ClientSettingsRouteError.oversizedCatalog }
                    nextSequence += 1
                    version = nextSequence
                }
                let item = ClientSettingsSearchItem(ticket: .init(scope: scope, version: version, identifier: id),
                    title: title, section: section, explanation: explanation, terms: terms, route: route, unavailableReason: unavailable)
                next[id] = Record(fingerprint: fingerprint, item: item)
                nextOrder.append(id)
            }
            try append("root", route: .root, title: localized("Title", "Exteraless Settings"), section: "")
            try append("search", route: .search, title: localized("Search.Title", "Search Exteraless settings"), section: "")
            var seen = Set<String>()
            for definition in definitions {
                guard ClientSettingDefinition.isValidKey(definition.key), seen.insert(definition.key).inserted else {
                    throw ClientSettingsRouteError.ambiguous
                }
                let key = definition.key
                guard Self.bounded(definition.title, bytes: 2048), Self.bounded(definition.section, bytes: 512),
                      Self.bounded(definition.explanation ?? "", bytes: 8192), definition.androidSymbols.count <= 64 else {
                    throw ClientSettingsRouteError.oversizedCatalog
                }
                guard definition.section != "AI state", !ExteraConfigCompatibility.keys.contains(key),
                      !key.hasPrefix(ExteraConfigCompatibility.prefix) else { continue }
                if ClientAPIFeatures.requiresNativeEditor(key), !ClientAPIFeatures.definitions.contains(where: { $0.key == key }) { continue }
                let ownerID: String? = ClientAPIFeatures.requiresNativeEditor(key) ? "clientAPI.edit"
                    : key == "cloud.includeApiKeys" ? "cloud.settings" : nil
                let owner = ownerID.flatMap { byAction[$0] }
                let unavailable: String?
                if ownerID != nil {
                    unavailable = owner == nil ? "The owning native Cloud/API editor is not available for this account." : owner?.unavailableReason
                } else if secretKeys.contains(key) && !definition.isSecret {
                    unavailable = "Secure storage migration needs to complete."
                } else { unavailable = nil }
                try append("setting:" + key, definition: definition, action: owner,
                    route: ownerID.map(ClientSettingsRoute.action) ?? .setting(key),
                    title: localized("Setting." + key + ".Title", definition.title),
                    section: localized("Section." + definition.section, definition.section),
                    explanation: definition.explanation.map { localized("Setting." + key + ".Explanation", $0) } ?? "",
                    unavailable: unavailable)
            }
            for action in actions {
                try append("action:" + action.id, action: action, route: .action(action.id),
                    title: localized("Action." + action.id, action.title), section: localized("Section." + action.section, action.section),
                    unavailable: action.unavailableReason)
            }
            for row in ClientSettingsSourceRoutes.unavailableRows {
                guard case let .unavailable(reason) = row.route else { continue }
                try append("original:" + row.page + ":" + row.names[0], route: row.route,
                    title: localized("Search.Original." + row.page + "." + row.names[0], row.title),
                    section: localized("Search.AndroidUnavailable", "Android settings · unavailable on iOS"),
                    explanation: reason, unavailable: reason)
            }
            guard next.count <= Self.maximumEntries else { throw ClientSettingsRouteError.oversizedCatalog }
            records = next
            order = nextOrder
            sequence = nextSequence
        } catch {
            records.removeAll()
            order.removeAll()
            throw error
        }
    }

    public func search(_ query: String, limit: Int = Self.maximumResults) -> [ClientSettingsSearchItem] {
        guard isActive, query.utf16.prefix(Self.maximumQueryUTF16 + 1).count <= Self.maximumQueryUTF16 else { return [] }
        let query = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty, terms.count <= 16 else { return [] }
        return items.compactMap { item -> (Int, ClientSettingsSearchItem)? in
            let title = Self.fold(item.title)
            let haystack = Self.fold(([item.title, item.section, item.explanation] + item.terms).joined(separator: "\n"))
            guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            let exact = title == query || item.terms.contains { Self.fold($0) == query }
            return ((exact ? 0 : title.hasPrefix(query) ? 1 : 2) + (item.isAvailable ? 0 : 4), item)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.ticket.identifier < rhs.1.ticket.identifier
        }.prefix(max(0, min(limit, Self.maximumResults))).map { $0.1 }
    }

    public func validate(_ ticket: ClientSettingsSearchTicket) throws -> ClientSettingsSearchItem {
        guard isActive, ticket.scope == scope else { throw ClientSettingsRouteError.retired }
        guard let item = records[ticket.identifier]?.item, item.ticket == ticket else { throw ClientSettingsRouteError.changed }
        if let reason = item.unavailableReason { throw ClientSettingsRouteError.unavailable(reason) }
        return item
    }

    public func resolve(_ request: ClientSettingsRouteRequest) throws -> ClientSettingsSearchItem {
        guard isActive else { throw ClientSettingsRouteError.retired }
        let route: ClientSettingsRoute
        switch request {
        case let .canonical(value): route = value
        case let .original(page, className, row): route = try ClientSettingsSourceRoutes.resolve(page: page, className: className, row: row)
        }
        let id: String
        switch route {
        case .root: id = "root"
        case .search: id = "search"
        case let .setting(key), let .row(key): id = "setting:" + key
        case let .action(key): id = "action:" + key
        case let .unavailable(reason): throw ClientSettingsRouteError.unavailable(reason)
        }
        guard let record = records[id] else {
            if case .original = request { throw ClientSettingsRouteError.unavailable("The native provider for this Original row is not registered in the current settings catalog.") }
            throw ClientSettingsRouteError.notFound
        }
        _ = try validate(record.item.ticket)
        // A row request is a presentation choice, never permission to bypass an
        // owned editor (notably clientAPI.*) or a registered definition version.
        if case .row = route, case let .setting(key) = record.item.route {
            let item = record.item
            return .init(ticket: item.ticket, title: item.title, section: item.section, explanation: item.explanation,
                         terms: item.terms, route: .row(key), unavailableReason: item.unavailableReason)
        }
        return record.item
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func bounded(_ text: String, bytes: Int) -> Bool { text.utf8.prefix(bytes + 1).count <= bytes }
}

public enum ClientSettingsLink {
    public static let maximumBytes = 2048

    public static func url(for route: ClientSettingsRoute) -> URL? {
        let path: String
        switch route {
        case .root: path = "exteraless"
        case .search: path = "exteraless/search"
        case let .setting(key): path = "exteraless/setting/" + key
        case let .row(key): path = "exteraless/row/" + key
        case let .action(id): path = "exteraless/action/" + id
        case .unavailable: return nil
        }
        guard (try? parsePath(path)) != nil else { return nil }
        return URL(string: "tg://settings/" + path)
    }

    /// nil means another URL namespace. Recognized malformed links throw, and
    /// must be consumed locally rather than falling through to network resolution.
    public static func parseURL(_ url: URL) throws -> ClientSettingsRouteRequest? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = parts.scheme?.lowercased(), host = parts.host?.lowercased()
        let path = parts.path.hasPrefix("/") ? String(parts.path.dropFirst()) : parts.path
        let native = scheme == "tg" && host == "settings" && (path == "exteraless" || path.hasPrefix("exteraless/"))
        let source = ["https", "http"].contains(scheme ?? "") && ["t.me", "telegram.me", "telegram.dog"].contains(host ?? "")
            && (path.hasPrefix("exteraless/") || path == "nasettings" || path.hasPrefix("nasettings/"))
        guard native || source else { return nil }
        guard url.absoluteString.utf8.count <= maximumBytes, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, !path.contains("%"), !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c") else { throw ClientSettingsRouteError.invalidLink }
        if native { return try parsePath(path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")) }
        let query = try queryValues(parts.queryItems ?? [], allowed: ["r", "row"])
        guard !(query["r"] != nil && query["row"] != nil) else { throw ClientSettingsRouteError.invalidLink }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= 2, !segments.contains("") else { throw ClientSettingsRouteError.invalidLink }
        let page = segments.count == 2 ? segments[1] : "settings"
        let row = query["r"] ?? query["row"]
        return .original(page: segments[0] == "nasettings" ? "nasettings/" + page : page, className: nil, row: row)
    }

    public static func parsePath(_ path: String) throws -> ClientSettingsRouteRequest? {
        guard path == "exteraless" || path.hasPrefix("exteraless/") || path.hasPrefix("exteraless?") else { return nil }
        guard path.utf8.count <= maximumBytes, let parts = URLComponents(string: "/" + path), parts.fragment == nil,
              !parts.percentEncodedPath.lowercased().contains("%2f"), !parts.percentEncodedPath.lowercased().contains("%5c") else {
            throw ClientSettingsRouteError.invalidLink
        }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.path.contains("//"), !parts.path.hasSuffix("/") else { throw ClientSettingsRouteError.invalidLink }
        if segments == ["exteraless", "source"] {
            let query = try queryValues(parts.queryItems ?? [], allowed: ["page", "class", "row"])
            guard !query.isEmpty else { throw ClientSettingsRouteError.invalidLink }
            return .original(page: query["page"], className: query["class"], row: query["row"])
        }
        guard parts.queryItems == nil else { throw ClientSettingsRouteError.invalidLink }
        if segments == ["exteraless"] { return .canonical(.root) }
        if segments == ["exteraless", "search"] { return .canonical(.search) }
        guard segments.count == 3, ClientSettingDefinition.isValidKey(segments[2]) else { throw ClientSettingsRouteError.invalidLink }
        switch segments[1] {
        case "setting": return .canonical(.setting(segments[2]))
        case "row": return .canonical(.row(segments[2]))
        case "action": return .canonical(.action(segments[2]))
        default: throw ClientSettingsRouteError.invalidLink
        }
    }

    private static func queryValues(_ items: [URLQueryItem], allowed: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        guard items.count <= allowed.count else { throw ClientSettingsRouteError.invalidLink }
        for item in items {
            guard allowed.contains(item.name), result[item.name] == nil, let value = item.value,
                  !value.isEmpty, value.utf8.count <= 256,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ClientSettingsRouteError.invalidLink }
            result[item.name] = value
        }
        return result
    }
}
