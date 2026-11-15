import Foundation

public struct ToolsPluginSchemaEvidence: Equatable, Sendable {
    public enum Guarantee: Equatable, Sendable { case unprovenDynamic, nativeImmutable }
    public let accountId: Int64
    public let owner: String
    public let sourceURL: URL
    public let sourceSHA256: String
    public let settingsRevision: UInt64
    public let settingsSHA256: String?
    public let schemaSHA256: String
    public let guarantee: Guarantee

    public init(accountId: Int64, owner: String, sourceURL: URL, sourceSHA256: String,
                settingsRevision: UInt64, settingsSHA256: String?, schemaSHA256: String,
                guarantee: Guarantee = .unprovenDynamic) {
        self.accountId = accountId; self.owner = owner; self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256; self.settingsRevision = settingsRevision
        self.settingsSHA256 = settingsSHA256; self.schemaSHA256 = schemaSHA256; self.guarantee = guarantee
    }

    func validate() throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard !owner.isEmpty, owner.utf8.count <= 512, sourceURL.isFileURL,
              digest(sourceSHA256), digest(schemaSHA256), settingsSHA256.map(digest) ?? true else {
            throw ToolsError.invalidArchive("Invalid native schema evidence.")
        }
    }
}

public enum ToolsPluginSchemaUse: Sendable { case export, restore }

/// Native, synchronous admission pin. It must exclude source/account/owner/revision
/// changes across body; it may not run Python or synchronously wait for MainActor.
/// Restore authority must come from the actual post-drain maintenance operation.
public protocol ToolsPluginSchemaValidity: Sendable {
    func withCurrent<T>(evidence: [String: ToolsPluginSchemaEvidence], use: ToolsPluginSchemaUse,
                        _ body: () throws -> T) throws -> T
}
