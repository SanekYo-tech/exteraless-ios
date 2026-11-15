import Foundation

public struct AppearanceAvatarPolicy: Equatable, Sendable {
    public enum Kind: Sendable { case regular, forum, community }

    public let corners: Int
    public let singleRadius: Bool

    public init(corners: Int = 28, singleRadius: Bool = false) {
        self.corners = min(28, max(0, corners))
        self.singleRadius = singleRadius
    }

    public var squareness: Double { 1.0 - Double(corners) / 28.0 }
    public var preservesNativeShape: Bool { corners == 28 && !singleRadius }

    /// AppearanceConfig.getAvatarCorners, in logical points rather than Android px.
    public func radius(size: Double, kind: Kind = .regular, hasStories: Bool = false) -> Double {
        guard size.isFinite, size > 0, corners > 0 else { return 0 }
        var value = size * Double(corners) / 56.0
        if hasStories { value -= 2.5 }
        if !singleRadius {
            switch kind {
            case .regular: break
            case .forum: value = floor(value) * 42.0 / 64.0
            case .community: value *= 40.0 / 72.0
            }
        }
        return min(size * 0.5, max(0, ceil(value)))
    }

    public func onlineDotOffset(base: Double, radius: Double) -> Double {
        return base + (radius / sqrt(2.0) - base) * squareness
    }
}

public enum AppearanceNumberPolicy {
    /// Android intentionally does not add grouping separators in this mode.
    public static func fullNumberOverride(_ number: Int, disableRounding: Bool) -> String? {
        return disableRounding ? String(number) : nil
    }
}

public enum AppearanceHeaderPolicy {
    public static func title(mode: Int, custom: String, appName: String, chatsTitle: String, username: String?, displayName: String?) -> String {
        func singleLine(_ text: String?) -> String {
            String((text ?? "").split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        }
        let value: String
        switch mode {
        case 1:
            let username = singleLine(username)
            value = username.isEmpty ? singleLine(displayName) : username
        case 2: value = singleLine(displayName)
        case 3: value = chatsTitle
        case 4: value = singleLine(custom)
        default: value = appName
        }
        return value.isEmpty ? appName : value
    }
}

public enum AppearanceTabPolicy {
    public static func selectedIndex<Id: Equatable>(current: Id?, visible: [Id], fallback: Id) -> Int? {
        if let current, let index = visible.firstIndex(of: current) { return index }
        return visible.firstIndex(of: fallback) ?? (visible.isEmpty ? nil : 0)
    }
}

public enum AppearanceFolderPolicy {
    public static func unreadCount(all: Int, unmuted: Int, mode: Int) -> Int {
        switch mode {
        case 1: return min(max(0, all), max(0, unmuted))
        case 2: return 0
        default: return max(0, all)
        }
    }

    /// Returns the rendered title and the transform for existing UTF-16 entities.
    /// Custom-emoji attributes must not shift by Swift Character count.
    public static func title(_ original: String, mode: Int, allChats: Bool) -> (text: String, entityOffset: Int, originalLimit: Int) {
        let first = original.first.map(String.init) ?? ""
        let hasLeadingEmoji = first.unicodeScalars.contains { $0.value >= 0x2300 && $0.properties.isEmoji }
        if mode == 1 {
            if hasLeadingEmoji { return (first, 0, first.utf16.count) }
            return (allChats ? "💬" : "📁", 0, 0)
        } else if mode == 2 && !hasLeadingEmoji {
            let prefix = (allChats ? "💬" : "📁") + " "
            return (prefix + original, prefix.utf16.count, original.utf16.count)
        }
        return (original, 0, original.utf16.count)
    }
}

public enum AppearanceTimePolicy {
    public static func seconds(_ seconds: Int32, explicitlyRequested: Bool, showSeconds: Bool) -> Int32? {
        return explicitlyRequested || showSeconds ? seconds : nil
    }
}

public enum AppearanceChatThemePolicy {
    /// Suppression is a render-time choice, never deletion of the saved per-chat
    /// theme/wallpaper. Re-enabling must restore both original values.
    public static func resolve<Theme, Wallpaper>(enabled: Bool, theme: Theme?, wallpaper: Wallpaper?) -> (theme: Theme?, wallpaper: Wallpaper?) {
        return enabled ? (theme, wallpaper) : (nil, nil)
    }
}

public struct AppearanceListPolicy: Equatable, Sendable {
    public let radius: Int
    public let separateHeaders: Bool
    public let segmented: Bool
    public let showsDividers: Bool
    public let materialRows: Bool

    public init(radius: Int = 20, separateHeaders: Bool = true, dividerStyle: Int = 1, materialRows: Bool = false) {
        self.radius = min(28, max(0, radius))
        self.materialRows = materialRows
        self.segmented = dividerStyle == 2 || materialRows
        self.separateHeaders = separateHeaders || self.segmented
        self.showsDividers = dividerStyle == 1 && !materialRows
    }

    public func minimumRowHeight(hasDetail: Bool) -> Double {
        if materialRows { return hasDetail ? 72 : 56 }
        return hasDetail ? 64 : 50
    }
}

public enum AppearancePresencePolicy {
    public enum RelativeValue: Equatable, Sendable {
        case justNow
        case minutes(Int32)
        case hours(Int32)
    }

    /// Call only for a known timestamp; never for Telegram's privacy buckets.
    public static func relativeValue(lastSeen: Int32, now: Int32, enabled: Bool, expanded: Bool = false) -> RelativeValue? {
        guard enabled, !expanded else { return nil }
        let elapsed = max(Int64(0), Int64(now) - Int64(lastSeen))
        if elapsed < 60 { return .justNow }
        if elapsed < 3600 { return .minutes(Int32(elapsed / 60)) }
        if elapsed < 86400 { return .hours(Int32(elapsed / 3600)) }
        return nil
    }

    public static func nextRelativeRefresh(lastSeen: Int32, now: Int32, enabled: Bool) -> Double? {
        guard enabled else { return nil }
        let elapsed = max(Int64(0), Int64(now) - Int64(lastSeen))
        if elapsed < 60 { return Double(60 - elapsed) }
        if elapsed < 3600 { return Double(60 - elapsed % 60) }
        if elapsed < 86400 { return Double(3600 - elapsed % 3600) }
        return nil
    }
}

public struct AppearanceMenuLayout: Equatable, Sendable {
    public static let divider = -1
    public static let settings = 8
    public static let knownIds = [18, 14, 105, 2, 6, 3, 10, 11, 8, 101, 102, 17, 106, 107, 108, 109, 110, 111]

    public var visible: [Int]
    public var hidden: [Int]

    public init(rawValue: String, availableIds: [Int], settingsInTabs: Bool = true, preserveUnavailable: Bool = false) {
        // A provider may unregister while the editor is open. Retain valid stored
        // extension IDs as well as original IDs until the user explicitly removes
        // them; capability filtering belongs to presentation, not serialization.
        let storedIds = rawValue.prefix(8192).split(whereSeparator: { $0 == "," || $0 == ";" }).prefix(256).compactMap { token -> Int? in
            guard let id = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0, id <= Int(Int32.max) else { return nil }
            return id
        }
        let known = Set(Self.knownIds).union(availableIds).union(preserveUnavailable ? storedIds : [])
        let available = preserveUnavailable ? known : Set(availableIds).intersection(Self.knownIds)
        if rawValue.isEmpty {
            // MainMenuLayout.getDefaultLayout; unavailable native routes are omitted.
            visible = ([14] + (settingsInTabs ? [] : [18]) + [2] + (settingsInTabs ? [] : [6]) + [11, 109, 106, 105] + (settingsInTabs ? [] : [8])).filter { available.contains($0) }
            hidden = []
        } else {
            let sections = rawValue.prefix(8192).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            visible = Self.read(sections.first.map(String.init) ?? "", available: available, dividers: true)
            hidden = Self.read(sections.count > 1 ? String(sections[1]) : "", available: available, dividers: false)
        }
        let visibleIds = Set(visible)
        hidden.removeAll { visibleIds.contains($0) }
        let orderedIds = preserveUnavailable ? Self.knownIds + availableIds.filter { !Self.knownIds.contains($0) } : availableIds
        for id in orderedIds where available.contains(id) && !visible.contains(id) && !hidden.contains(id) {
            hidden.append(id)
        }
        if !settingsInTabs && available.contains(Self.settings) && !visible.contains(Self.settings) {
            hidden.removeAll { $0 == Self.settings }
            visible.append(Self.settings)
        }
    }

    public var rawValue: String {
        visible.map(String.init).joined(separator: ",") + ";" + hidden.map(String.init).joined(separator: ",")
    }

    private static func read(_ value: String, available: Set<Int>, dividers: Bool) -> [Int] {
        var result: [Int] = []
        for token in value.split(separator: ",").prefix(128) {
            guard let id = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if id == divider && dividers {
                result.append(id)
            } else if available.contains(id) && !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }
}

public struct AppearanceAppIcon: Equatable, Sendable {
    /// The CFBundleAlternateIcons dictionary key, not the image filename.
    public let name: String
    public let imageName: String
    public let isDefault: Bool
}

public enum AppearanceAppIconPolicy {
    public static func catalog(info: [String: Any], isPad: Bool) -> [AppearanceAppIcon] {
        let phone = info["CFBundleIcons"] as? [String: Any]
        let icons = (isPad ? info["CFBundleIcons~ipad"] as? [String: Any] : nil) ?? phone ?? [:]
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let primaryImage = (primary["CFBundleIconFiles"] as? [String])?.first ?? primary["CFBundleIconName"] as? String ?? ""
        var result = [AppearanceAppIcon(name: "Default", imageName: primaryImage, isDefault: true)]
        let alternatives = icons["CFBundleAlternateIcons"] as? [String: [String: Any]] ?? [:]
        let preferredOrder = ["Blue", "Black", "BlueClassic", "BlackClassic", "BlueFilled", "BlackFilled", "WhiteFilled"]
        let names = alternatives.keys.sorted { lhs, rhs in
            let l = preferredOrder.firstIndex(of: lhs) ?? preferredOrder.count
            let r = preferredOrder.firstIndex(of: rhs) ?? preferredOrder.count
            return l == r ? lhs < rhs : l < r
        }
        for name in names {
            guard let entry = alternatives[name],
                  let image = entry["CFBundleIconName"] as? String ?? (entry["CFBundleIconFiles"] as? [String])?.first,
                  !image.isEmpty else { continue }
            result.append(AppearanceAppIcon(name: name, imageName: image, isDefault: false))
        }
        return result
    }
}
