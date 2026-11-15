import Foundation

/// Numeric CFBundleVersion components; "100" is newer than "99", and large CI
/// build numbers are never converted to floating point or compared as strings.
public struct ToolsBuildNumber: Equatable, Comparable, Sendable {
    public let components: [UInt64]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4, string.utf8.count <= 80,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let values = parts.compactMap { UInt64($0) }
        guard values.count == parts.count else { return nil }
        var normalized = values
        while normalized.count > 1 && normalized.last == 0 { normalized.removeLast() }
        self.components = normalized
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct ToolsReleaseVersion: Equatable, Sendable {
    public let marketing: ToolsBuildNumber
    public let prerelease: String?
    public let build: ToolsBuildNumber?

    /// Release convention: v13.1.1+123 or v13.1.1-beta.2+123. Builds without
    /// comparable metadata stay "unknown", rather than being called up to date.
    public init?(tag: String, buildNumber: String? = nil) {
        var source = tag
        if source.hasPrefix("ios-") { source.removeFirst(4) }
        if source.hasPrefix("v") { source.removeFirst() }
        let plus = source.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let dash = plus[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard dash[0].contains("."), let marketing = ToolsBuildNumber(String(dash[0])) else { return nil }
        let prerelease = dash.count > 1 ? String(dash[1]) : nil
        if let prerelease {
            guard !prerelease.isEmpty, prerelease.utf8.count <= 100,
                  !prerelease.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }),
                  prerelease.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        }
        let buildString = buildNumber ?? (plus.count > 1 ? String(plus[1]) : nil)
        let build = buildString.flatMap(ToolsBuildNumber.init)
        if buildString != nil && build == nil { return nil }
        self.marketing = marketing
        self.prerelease = prerelease
        self.build = build
    }

    public enum Comparison: Equatable, Sendable { case newer, notNewer, unknown }

    public func compared(to installed: ToolsReleaseVersion) -> Comparison {
        if marketing != installed.marketing { return marketing > installed.marketing ? .newer : .notNewer }
        if prerelease != installed.prerelease {
            guard let prerelease else { return .newer }
            guard let installedPrerelease = installed.prerelease else { return .notNewer }
            let remote = prerelease.split(separator: ".", omittingEmptySubsequences: false)
            let local = installedPrerelease.split(separator: ".", omittingEmptySubsequences: false)
            for i in 0..<max(remote.count, local.count) {
                if i >= remote.count { return .notNewer }
                if i >= local.count { return .newer }
                if remote[i] == local[i] { continue }
                let r = UInt64(remote[i]), l = UInt64(local[i])
                if let r, let l { return r > l ? .newer : .notNewer }
                if r != nil { return .notNewer }
                if l != nil { return .newer }
                return String(remote[i]).compare(String(local[i]), options: [.numeric, .literal]) == .orderedDescending ? .newer : .notNewer
            }
        }
        guard let build, let localBuild = installed.build else { return .unknown }
        return build > localBuild ? .newer : .notNewer
    }
}

public struct ToolsReleaseRepository: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) throws {
        guard ToolsFileSafety.isComponent(owner), ToolsFileSafety.isComponent(name),
              !owner.contains(".."), !name.contains("..") else { throw ToolsError.invalidRelease }
        self.owner = owner
        self.name = name
    }

    public static let application = try! ToolsReleaseRepository(owner: "SanekYo-tech", name: "exteraless-ios")
    public var releasesURL: URL { URL(string: "https://github.com/\(owner)/\(name)/releases")! }
    public var apiURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases?per_page=20")! }

    public func acceptsAssetURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        let components = url.pathComponents
        return components.count >= 7 && components[1].lowercased() == owner.lowercased()
            && components[2].lowercased() == name.lowercased()
            && components[3] == "releases" && components[4] == "download"
            && !components.contains("..")
    }
}

public struct ToolsGitHubRelease: Equatable, Sendable {
    public let id: Int64
    public let tag: String
    public let name: String
    public let notes: String
    public let prerelease: Bool
    public let releaseURL: URL
    public let asset: Asset
    public let version: ToolsReleaseVersion?

    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int64
        public let sha256: String?
    }
}

public enum ToolsUpdateSchedule {
    public static let interval: TimeInterval = 6 * 60 * 60
    public static func shouldCheck(channel: Int, lastAttempt: Date?, now: Date) -> Bool {
        guard channel == 1 || channel == 2 else { return false }
        guard let lastAttempt else { return true }
        return abs(now.timeIntervalSince(lastAttempt)) >= interval
    }
}
