import Foundation

public enum ChatTrackingRulesError: Error, LocalizedError, Sendable {
    case tooLarge
    case invalidFilter
    case storage
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The tracking filter exceeds the supported size."
        case .invalidFilter: return "The response is not a supported URL-tracking filter."
        case .storage: return "The tracking filter couldn't be saved. The previous rules remain active."
        case .cancelled: return "The tracking filter update was cancelled."
        }
    }
}

/// Document-only AdGuard removeparam rules. Immutable compiled regexes are safe to share; match
/// budgets are local to each call. No scriptlet, redirect, resource-blocking or network rule executes.
public final class ChatAdGuardRules: @unchecked Sendable {
    public static let maximumSourceBytes = 2 * 1024 * 1024
    public let ruleCount: Int
    public let ignoredRuleCount: Int
    public let updated: String?
    private let generalRules: [Rule]
    private let hostRules: [String: [Rule]]

    // Explicitly a small fallback, not a copy of the missing Android bundled asset. A bundled or
    // user-updated full AdGuard list replaces it through the same parser and precedence rules.
    public static let fallbackSource = """
    ! Exteraless native fallback URL-tracking rules
    $removeparam=/^utm_/i
    $removeparam=/^(fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|yclid|_openstat|igshid|igsh|mkt_tok|vero_id|oly_anon_id|oly_enc_id)(=|$)/i
    """

    public init(source: String, requireUpdatedDate: Bool = false) throws {
        guard source.utf8.count <= Self.maximumSourceBytes else { throw ChatTrackingRulesError.tooLarge }
        var general: [Rule] = []
        var byHost: [String: [Rule]] = [:]
        var count = 0
        var ignored = 0
        var updated: String?
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("! TimeUpdated:") {
                let value = line.dropFirst("! TimeUpdated:".count).trimmingCharacters(in: .whitespaces)
                let date = String(value.prefix(10))
                let parts = date.split(separator: "-")
                if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                   let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                   (1970 ... 9999).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day) { updated = date }
            }
            guard let rule = Self.parse(line) else {
                if !line.hasPrefix("!") && line.contains("removeparam") { ignored += 1 }
                continue
            }
            count += 1
            guard count <= 8192 else { throw ChatTrackingRulesError.tooLarge }
            if case let .host(host, nil, _) = rule.url {
                byHost[host, default: []].append(rule)
            } else {
                general.append(rule)
            }
        }
        guard count > 0, !requireUpdatedDate || updated != nil else { throw ChatTrackingRulesError.invalidFilter }
        self.ruleCount = count
        self.ignoredRuleCount = ignored
        self.updated = updated
        self.generalRules = general
        self.hostRules = byHost
    }

    public func clean(_ url: String, maximumEvaluationTime: TimeInterval = 0.02) -> String {
        guard let parsed = ParsedURL(url), !parsed.protected, maximumEvaluationTime.isFinite, maximumEvaluationTime > 0 else { return url }
        let budget = MatchBudget(duration: min(0.05, maximumEvaluationTime))
        var candidates = self.generalRules
        var domain = parsed.host[...]
        while !domain.isEmpty {
            if let rules = self.hostRules[String(domain)] { candidates.append(contentsOf: rules) }
            guard let dot = domain.firstIndex(of: ".") else { break }
            domain = domain[domain.index(after: dot)...]
        }
        var exceptions: [Parameter] = []
        var removals: [Parameter] = []
        for rule in candidates {
            if budget.expired { return url }
            guard rule.matches(parsed: parsed, fullURL: url, budget: budget) else { continue }
            if rule.exception {
                if case .all = rule.parameter { return url }
                exceptions.append(rule.parameter)
            } else {
                removals.append(rule.parameter)
            }
        }
        guard !removals.isEmpty, !budget.expired else { return url }
        var retained: [String] = []
        for part in parsed.parts {
            if budget.expired { return url }
            let name = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let remove = removals.contains { $0.matches(name: name, raw: part, budget: budget) }
                && !exceptions.contains { $0.matches(name: name, raw: part, budget: budget) }
            if !remove { retained.append(part) }
        }
        let removeEmptyQuery = parsed.parts.isEmpty && removals.contains { if case .all = $0 { return true }; return false }
        guard !budget.expired, retained.count != parsed.parts.count || removeEmptyQuery else { return url }
        return parsed.prefix + (retained.isEmpty ? "" : "?" + retained.joined(separator: "&")) + parsed.fragment
    }

    /// Shared by the preview-only host mapper and tracking cleanup. Signed/user-info URLs
    /// and unparseable/non-HTTP inputs must pass through byte-for-byte at every entry.
    public static func allowsRewriting(_ url: String) -> Bool {
        guard url.utf8.count <= 8192, !url.contains(where: \.isWhitespace),
              let components = URLComponents(string: url), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil else { return false }
        // Tracking removal itself needs a query; preview host mapping also applies to a
        // normal query-less public URL. Both share the same query signature exclusion.
        if components.percentEncodedQuery == nil { return true }
        guard let parsed = ParsedURL(url) else { return false }
        return !parsed.protected
    }

    private struct ParsedURL {
        let host: String
        let prefix: String
        let fragment: String
        let pathAndQuery: String
        let parts: [String]
        let protected: Bool

        init?(_ url: String) {
            guard url.utf8.count <= 8192, !url.contains(where: \.isWhitespace),
                  let components = URLComponents(string: url), let host = components.host,
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  components.percentEncodedQuery != nil, let queryStart = url.firstIndex(of: "?") else { return nil }
            self.host = host.lowercased()
            let end = url[queryStart...].firstIndex(of: "#") ?? url.endIndex
            self.prefix = String(url[..<queryStart])
            self.fragment = String(url[end...])
            let query = String(url[url.index(after: queryStart) ..< end])
            self.parts = query.isEmpty ? [] : query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
            guard self.parts.count <= 256 else { return nil }
            let signatures: Set<String> = ["signature", "sig", "token", "access_token", "auth", "hash", "hmac", "key", "x-amz-signature", "x-goog-signature", "policy"]
            self.protected = components.user != nil || components.password != nil || self.parts.contains { part in
                let name = part.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return signatures.contains((name.removingPercentEncoding ?? name).lowercased())
            }
            guard let schemeEnd = self.prefix.range(of: "://")?.upperBound else { return nil }
            let pathStart = self.prefix[schemeEnd...].firstIndex(of: "/") ?? self.prefix.endIndex
            self.pathAndQuery = String(self.prefix[pathStart...]) + "?" + query
        }
    }

    private final class MatchBudget {
        let deadline: TimeInterval
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= self.deadline }
        init(duration: TimeInterval) { self.deadline = ProcessInfo.processInfo.systemUptime + duration }
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String, budget: MatchBudget) -> Bool {
        if budget.expired { return false }
        var result = false
        regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(location: 0, length: (value as NSString).length)) { match, _, stop in
            if budget.expired { stop.pointee = true; return }
            if match != nil { result = true; stop.pointee = true }
        }
        return result
    }

    private enum URLMatcher {
        case any
        case host(String, NSRegularExpression?, NSRegularExpression?)
        case full(NSRegularExpression)
    }

    private indirect enum Parameter {
        case all
        case literal(String)
        case pattern(NSRegularExpression)
        case inverted(Parameter)

        func matches(name: String, raw: String, budget: MatchBudget) -> Bool {
            switch self {
            case .all: return true
            case let .literal(value): return name == value
            case let .pattern(regex): return ChatAdGuardRules.matches(regex, raw, budget: budget)
            case let .inverted(inner): return !inner.matches(name: name, raw: raw, budget: budget)
            }
        }
    }

    private struct Rule {
        let exception: Bool
        let url: URLMatcher
        let parameter: Parameter
        let include: [String]
        let exclude: [String]

        func matches(parsed: ParsedURL, fullURL: String, budget: MatchBudget) -> Bool {
            func hostMatches(_ value: String) -> Bool { parsed.host == value || parsed.host.hasSuffix("." + value) }
            if !self.include.isEmpty && !self.include.contains(where: hostMatches) { return false }
            if self.exclude.contains(where: hostMatches) { return false }
            switch self.url {
            case .any: return true
            case let .full(regex): return ChatAdGuardRules.matches(regex, fullURL, budget: budget)
            case let .host(host, hostRegex, pathRegex):
                let matchesHost = hostRegex.map { ChatAdGuardRules.matches($0, parsed.host, budget: budget) } ?? hostMatches(host)
                return matchesHost && (pathRegex.map { ChatAdGuardRules.matches($0, parsed.pathAndQuery, budget: budget) } ?? true)
            }
        }
    }

    private static func parse(_ line: String) -> Rule? {
        guard !line.isEmpty, line.utf16.count <= 4096, !line.hasPrefix("!"), !line.hasPrefix("["),
              !["##", "#@#", "#%#", "#$#"].contains(where: line.contains) else { return nil }
        let exception = line.hasPrefix("@@")
        let body = exception ? String(line.dropFirst(2)) : line
        guard let dollar = self.modifierDollar(body) else { return nil }
        let pattern = String(body[..<dollar])
        let modifiers = self.splitModifiers(String(body[body.index(after: dollar)...]))
        let nonDocument: Set<String> = ["xmlhttprequest", "script", "image", "stylesheet", "font", "media", "object", "subdocument", "websocket", "webrtc", "ping", "other", "popup", "object-subrequest", "csp", "webtransport"]
        let document: Set<String> = ["document", "main_frame", "main-frame", "all"]
        let neutral: Set<String> = ["important", "third-party", "match-case"]
        let disqualifying: Set<String> = ["first-party", "specifichide", "generichide", "elemhide"]
        let prefixes = ["app=", "header=", "method=", "replace=", "csp=", "redirect=", "redirect-rule=", "rewrite=", "jsonprune", "removeheader=", "permissions=", "cookie=", "stealth=", "to=", "from=", "client=", "ctag=", "dnstype=", "dnsrewrite="]
        var hasRemove = false
        var parameter: String?
        var domain: String?
        var denyAllow: String?
        var hasDocument = false
        var hasNonDocument = false
        for modifier in modifiers {
            if modifier == "removeparam" { hasRemove = true; parameter = nil }
            else if modifier.hasPrefix("removeparam=") { hasRemove = true; parameter = String(modifier.dropFirst(12)) }
            else if modifier.hasPrefix("domain=") { domain = String(modifier.dropFirst(7)) }
            else if modifier.hasPrefix("denyallow=") { denyAllow = String(modifier.dropFirst(10)) }
            else if neutral.contains(modifier) {}
            else if document.contains(modifier) { hasDocument = true }
            else if nonDocument.contains(modifier) { hasNonDocument = true }
            else if modifier.hasPrefix("~") { if disqualifying.contains(String(modifier.dropFirst())) { return nil } }
            else if disqualifying.contains(modifier) || prefixes.contains(where: modifier.hasPrefix) { return nil }
            else { return nil }
        }
        guard hasRemove, !hasNonDocument || hasDocument, let parameterMatcher = self.parseParameter(parameter), let urlMatcher = self.parseURL(pattern) else { return nil }
        let domains = self.domains(domain)
        return Rule(exception: exception, url: urlMatcher, parameter: parameterMatcher, include: domains.0, exclude: domains.1 + self.domains(denyAllow).0)
    }

    private static func parseParameter(_ value: String?, depth: Int = 0) -> Parameter? {
        guard depth < 8 else { return nil }
        guard let value else { return .all }
        if value.hasPrefix("~") {
            guard let inner = self.parseParameter(String(value.dropFirst()), depth: depth + 1) else { return nil }
            if case .all = inner { return nil }
            return .inverted(inner)
        }
        if value.hasPrefix("/") {
            guard let slash = value.lastIndex(of: "/"), slash > value.startIndex else { return nil }
            let flags = value[value.index(after: slash)...]
            let options: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: String(value[value.index(after: value.startIndex) ..< slash]), options: options) else { return nil }
            return .pattern(regex)
        }
        return .literal(value)
    }

    private static func modifierDollar(_ body: String) -> String.Index? {
        var inRegex = false
        var last: String.Index?
        var index = body.startIndex
        var previous: Character = " "
        while index < body.endIndex {
            let value = body[index]
            if value == "\\" {
                index = body.index(after: index)
                if index < body.endIndex { previous = body[index]; index = body.index(after: index) }
                continue
            }
            if value == "/" { inRegex = inRegex ? false : (previous == "=" || previous == "$" || index == body.startIndex) }
            if value == "$" && !inRegex { last = index }
            previous = value
            index = body.index(after: index)
        }
        return last
    }

    private static func splitModifiers(_ value: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        var inRegex = false
        var index = value.startIndex
        while index < value.endIndex {
            let c = value[index]
            if c == "\\" {
                buffer.append(c)
                index = value.index(after: index)
                if index < value.endIndex { buffer.append(value[index]); index = value.index(after: index) }
                continue
            }
            if c == "/" { inRegex = inRegex ? false : buffer.last == "=" }
            if c == "," && !inRegex { result.append(buffer); buffer = "" }
            else { buffer.append(c) }
            index = value.index(after: index)
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }

    private static func parseURL(_ pattern: String) -> URLMatcher? {
        if pattern.isEmpty || pattern == "*" { return .any }
        if pattern.count >= 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/") {
            return (try? NSRegularExpression(pattern: String(pattern.dropFirst().dropLast()))).map(URLMatcher.full)
        }
        guard pattern.hasPrefix("||") else { return nil }
        let body = pattern.dropFirst(2)
        let end = body.firstIndex(where: { $0 == "^" || $0 == "/" }) ?? body.endIndex
        let host = String(body[..<end]).lowercased()
        guard !host.isEmpty else { return nil }
        let rest = String(body[end...])
        var hostRegex: NSRegularExpression?
        if host.contains("*") {
            let pattern = host.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[^/]+")
            guard let regex = try? NSRegularExpression(pattern: "^(?:.+\\.)?" + pattern + "$") else { return nil }
            hostRegex = regex
        }
        var pathRegex: NSRegularExpression?
        if !rest.isEmpty {
            var pattern = ""
            for character in rest {
                if character == "*" { pattern += ".*" }
                else if character == "^" { pattern += "(?:[^A-Za-z0-9._%~-]|$)" }
                else if "\\.+?()[]{}|".contains(character) { pattern += "\\" + String(character) }
                else { pattern.append(character) }
            }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            pathRegex = regex
        }
        return .host(host, hostRegex, pathRegex)
    }

    private static func domains(_ value: String?) -> ([String], [String]) {
        var include: [String] = []
        var exclude: [String] = []
        for raw in value?.split(separator: "|") ?? [] {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("~") { exclude.append(String(value.dropFirst())) }
            else if !value.isEmpty { include.append(value) }
        }
        return (include, exclude)
    }
}
