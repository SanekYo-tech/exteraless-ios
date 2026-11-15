import Foundation

public struct NativeServiceFileRegistration: Sendable {
    public let fileExtension: String
    public let whitelist: [String]
    public let blacklist: [String]

    public init(_ value: PluginJSONValue) throws {
        let model = try NativeServiceWire.object(value, name: "fileRegister.model", keys: ["extension", "whitelist", "blacklist", "icon"])
        var ext = try NativeServiceWire.string(model["extension"], name: "extension", maximum: 64)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard !ext.isEmpty, ext.utf8.count <= 32,
              ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-+".unicodeScalars.contains($0) }) else {
            throw BridgeFailure.malformed("File extension must be a literal suffix, without a path, wildcard or compound extension")
        }
        if let icon = model["icon"], try NativeServiceWire.bool(icon, name: "icon") {
            throw BridgeFailure.unimplemented("Android file icon factories have no native document-icon site")
        }
        fileExtension = ext
        // FilesControllerJava.passesFilters (258-277) matches filename substrings,
        // despite the Python FileInfo's misleading whitelist_places parameter.
        whitelist = try NativeServiceWire.strings(model["whitelist"], name: "whitelist").map { $0.lowercased() }
        blacklist = try NativeServiceWire.strings(model["blacklist"], name: "blacklist").map { $0.lowercased() }
    }

    public func matches(fileName: String) -> Bool {
        let name = fileName.lowercased()
        guard (fileName as NSString).pathExtension.lowercased() == fileExtension else { return false }
        return (whitelist.isEmpty || whitelist.contains(where: { name.contains($0) })) && !blacklist.contains(where: { name.contains($0) })
    }
}

/// Only callsites with concrete native hooks may be enabled by the composition
/// root. Empty sets make registration fail instead of advertising an inert hook.
public enum NativeServiceInterceptionSite: String, Hashable, Sendable {
    case chatDocument = "OpenChatMessage.document"
    case externalURL = "OpenUrl.openExternalUrlImpl"
    case applicationURL = "AppDelegate.openURL"
}

public struct NativeServiceFileOpenContext: Sendable {
    public let fileName: String
    public let value: PluginJSONValue

    public init(fileName: String, path: String, mime: String?, account: Int32,
                place: String, message: PluginJSONValue? = nil) throws {
        guard !fileName.isEmpty, fileName.utf8.count <= 1024, path.utf8.count <= 4096,
              (path as NSString).isAbsolutePath else { throw BridgeFailure.malformed("Invalid native file-open context") }
        self.fileName = fileName
        var value: [String: PluginJSONValue] = [
            "file_name": .string(fileName), "path": .string(path), "file": .string(path),
            "account": .integer(Int64(account)), "place": .string(place),
            // There is no Java Activity/BaseFragment in the native file opener.
            "activity": .null, "parent_fragment": .null
        ]
        value["mime"] = mime.map(PluginJSONValue.string)
        value["message"] = message
        self.value = .object(value)
    }
}

public struct NativeServiceIntentContext: Sendable {
    public let scheme: String?
    public let host: String?
    public let path: String
    public let query: [String: String]
    public let action: String
    public let mimeType: String?
    public let categories: Set<String>
    public let flags: UInt32
    public let value: [String: PluginJSONValue]

    public init(url: URL, account: Int32, fromIntent: Bool = false,
                action: String = "android.intent.action.VIEW", mimeType: String? = nil,
                categories: Set<String> = [], flags: UInt32 = 0) throws {
        guard url.absoluteString.utf8.count <= 16_384,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme != nil else {
            throw BridgeFailure.malformed("Intent requires a bounded absolute URL")
        }
        // Android normalizes opaque tg:resolve?domain=x to tg://resolve?domain=x.
        // Preserve NSURL's mailto/tel parsing; only Telegram uses this authority form.
        if parts.scheme?.lowercased() == "tg", parts.host == nil,
           let colon = url.absoluteString.firstIndex(of: ":") {
            let suffix = String(url.absoluteString[url.absoluteString.index(after: colon)...])
            if !suffix.hasPrefix("/"), let hierarchical = URLComponents(string: "tg://" + suffix) { parts = hierarchical }
        }
        var query: [String: String] = [:]
        for pair in (parts.percentEncodedQuery ?? "").split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let encodedName = pieces.first, let name = String(encodedName).removingPercentEncoding, query[name] == nil else { continue }
            // Decode literal '+' before percent escapes: %2B is a plus, not space.
            let encodedValue = pieces.count == 2 ? String(pieces[1]) : ""
            query[name] = encodedValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? encodedValue
        }
        guard query.count <= 128, categories.count <= 64 else { throw BridgeFailure.malformed("Intent context exceeds native bounds") }
        self.scheme = parts.scheme
        self.host = parts.host
        self.path = parts.path
        self.query = query
        self.action = action
        self.mimeType = mimeType
        self.categories = categories
        self.flags = flags
        let queryValue = PluginJSONValue.object(query.mapValues(PluginJSONValue.string))
        var value: [String: PluginJSONValue] = [
            "data_string": .string(url.absoluteString), "account": .integer(Int64(account)),
            "from_intent": .bool(fromIntent), "action": .string(action),
            "flags": .integer(Int64(Int32(bitPattern: flags))), "categories": .array(categories.sorted().map(PluginJSONValue.string)),
            "scheme": parts.scheme.map(PluginJSONValue.string) ?? .null,
            "host": parts.host.map(PluginJSONValue.string) ?? .null, "path": .string(parts.path),
            "query": queryValue, "query_args": queryValue, "type": mimeType.map(PluginJSONValue.string) ?? .null
        ]
        if fromIntent {
            value["intent"] = .object(["platform": .string("ios"), "data": .string(url.absoluteString),
                "action": .string(action), "flags": .integer(Int64(Int32(bitPattern: flags))),
                "type": mimeType.map(PluginJSONValue.string) ?? .null,
                "categories": .array(categories.sorted().map(PluginJSONValue.string))])
        }
        self.value = value
    }
}

public struct NativeServiceIntentRegistration: Sendable {
    public let before: Bool
    public let priority: Int32
    public let schemes: [String]
    public let hosts: [String]
    public let pathTemplate: String?
    public let queryArguments: [String]
    public let action: String?
    public let mimeType: String?
    public let categories: [String]
    public let whitelistFlags: [UInt32]
    public let blacklistFlags: [UInt32]

    public init(_ value: PluginJSONValue) throws {
        let model = try NativeServiceWire.object(value, name: "intentRegister.model", keys: ["before", "priority", "filters"])
        before = try NativeServiceWire.bool(model["before"], name: "before")
        let filters = try NativeServiceWire.object(model["filters"] ?? .object([:]), name: "filters",
            keys: ["schemes", "hosts", "path_template", "query_args", "action", "type", "categories", "flags", "whitelist_flags", "blacklist_flags", "priority"])
        priority = Int32(try NativeServiceWire.integer(filters["priority"] ?? model["priority"] ?? .integer(0),
            name: "priority", range: Int64(Int32.min)...Int64(Int32.max)))
        schemes = try NativeServiceWire.strings(filters["schemes"], name: "schemes").map { $0.lowercased() }
        hosts = try NativeServiceWire.strings(filters["hosts"], name: "hosts").map { $0.lowercased() }
        queryArguments = try NativeServiceWire.strings(filters["query_args"], name: "query_args")
        categories = try NativeServiceWire.strings(filters["categories"], name: "categories")
        func optionalString(_ key: String, maximum: Int = 256) throws -> String? {
            guard let value = filters[key], value != .null else { return nil }
            return try NativeServiceWire.string(value, name: key, maximum: maximum)
        }
        pathTemplate = try optionalString("path_template", maximum: 2048)
        action = try optionalString("action")
        mimeType = try optionalString("type")
        whitelistFlags = try Self.flagMasks(filters["whitelist_flags"] ?? filters["flags"], name: "whitelist_flags")
        blacklistFlags = try Self.flagMasks(filters["blacklist_flags"], name: "blacklist_flags")
        if filters["flags"] != nil && filters["whitelist_flags"] != nil {
            throw BridgeFailure.malformed("Use flags or whitelist_flags, not both")
        }
        if let pathTemplate {
            for segment in pathTemplate.components(separatedBy: CharacterSet(charactersIn: "/.")) {
                if segment.contains("{") || segment.contains("}") {
                    guard segment.hasPrefix("{"), segment.hasSuffix("}"), segment.count > 2,
                          segment.dropFirst().dropLast().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                        throw BridgeFailure.malformed("path_template variables must occupy a complete segment")
                    }
                }
            }
        }
    }

    private static func flagMasks(_ value: PluginJSONValue?, name: String) throws -> [UInt32] {
        guard let value, value != .null else { return [] }
        let values: [PluginJSONValue]
        if case let .array(array) = value { values = array } else { values = [value] }
        guard values.count <= 32 else { throw BridgeFailure.malformed("Too many intent flag masks") }
        return try values.map {
            let mask = try NativeServiceWire.integer($0, name: name, range: Int64(Int32.min)...Int64(UInt32.max))
            return mask < 0 ? UInt32(bitPattern: Int32(mask)) : UInt32(mask)
        }
    }

    /// The installed native sites receive URLs, not Android activity intents.
    /// Reject filters that those sites can never produce instead of retaining an
    /// inactive registration or silently ignoring a promised SDK filter.
    public func validateNativeURLSites() throws {
        if let action, action != "android.intent.action.VIEW" {
            throw BridgeFailure.unimplemented("UnsupportedIntentAction: native URL sites expose ACTION_VIEW")
        }
        guard mimeType == nil else { throw BridgeFailure.unimplemented("Native URL sites have no Android intent MIME type") }
        guard categories.isEmpty else { throw BridgeFailure.unimplemented("Native URL sites have no Android activity categories") }
        guard whitelistFlags.allSatisfy({ $0 == 0 }) else { throw BridgeFailure.unimplemented("Native URL sites have no Android activity flags") }
    }

    /// Returns an independent per-handler context, so captures in one template do
    /// not contaminate later handlers. Both Java and SDK spellings are supplied.
    public func matchingContext(_ context: NativeServiceIntentContext) -> PluginJSONValue? {
        if !schemes.isEmpty && !schemes.contains(context.scheme?.lowercased() ?? "") { return nil }
        if !hosts.isEmpty && !hosts.contains(context.host?.lowercased() ?? "") { return nil }
        if let action, action != context.action { return nil }
        if let mimeType, mimeType != context.mimeType { return nil }
        guard queryArguments.allSatisfy({ context.query[$0] != nil }),
              categories.allSatisfy({ context.categories.contains($0) }),
              whitelistFlags.allSatisfy({ context.flags & $0 == $0 }),
              blacklistFlags.allSatisfy({ context.flags & $0 == 0 }) else { return nil }
        var extracted: [String: String] = [:]
        if var template = pathTemplate {
            if let slash = template.firstIndex(of: "/"), slash != template.startIndex {
                let hostTemplate = String(template[..<slash])
                guard Self.match(template: hostTemplate, value: context.host, separator: ".", extracted: &extracted) else { return nil }
                template = String(template[slash...])
            }
            guard Self.match(template: template, value: context.path, separator: "/", extracted: &extracted) else { return nil }
        }
        var value = context.value
        let captures = PluginJSONValue.object(extracted.mapValues(PluginJSONValue.string))
        value["path_vars"] = captures
        value["path_args"] = captures
        for (key, capture) in extracted where value[key] == nil { value[key] = .string(capture) }
        return .object(value)
    }

    private static func match(template: String, value: String?, separator: Character, extracted: inout [String: String]) -> Bool {
        guard let value else { return false }
        func segments(_ text: String) -> [Substring] {
            let text = separator == "/" ? text.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : text
            return text.isEmpty ? [] : text.split(separator: separator, omittingEmptySubsequences: false)
        }
        let templates = segments(template)
        let values = segments(value)
        guard templates.count == values.count else { return false }
        for (template, value) in zip(templates, values) {
            if template.hasPrefix("{"), template.hasSuffix("}") {
                guard !value.isEmpty else { return false }
                extracted[String(template.dropFirst().dropLast())] = String(value)
            } else if template.lowercased() != value.lowercased() { return false }
        }
        return true
    }
}
