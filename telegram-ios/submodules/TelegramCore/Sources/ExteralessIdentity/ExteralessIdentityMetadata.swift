import ExteralessCore
import Foundation

public struct ExteralessIdentityMetadata {
    public let id: String
    public let datacenterId: Int?
    public let datacenterSource: String?
    public let userLink: String?
}

public func exteralessIdentityPreferCommonGroups(defaultIsGifts: Bool, hasCommonGroups: Bool, explicitSelection: Bool = false) -> Bool {
    IdentityMetadataPolicy.preferCommonGroups(enabled: ExteralessIdentityPresentation.shared.policy.preferCommonGroupsTab,
        defaultIsGifts: defaultIsGifts, hasCommonGroups: hasCommonGroups, explicitSelection: explicitSelection)
}

/// Reads native descriptors only. A remote peer's avatar DC is not represented
/// as their home DC; statistics DC is preferred for a channel, as in Android.
public func exteralessIdentityMetadata(account: Account, peer: EnginePeer, cachedData: EngineCachedPeerData?) -> ExteralessIdentityMetadata? {
    guard let key = exteralessIdentityPeerKey(peer),
          let id = IdentityMetadataPolicy.displayedId(peer: key, type: ExteralessIdentityPresentation.shared.policy.idDcType) else { return nil }
    var dc: Int?
    var source: String?
    if peer.id == account.peerId {
        dc = account.network.datacenterId
        source = "Account DC"
    } else if let channel = cachedData as? CachedChannelData, channel.statsDatacenterId > 0 {
        dc = Int(channel.statsDatacenterId)
        source = "Statistics DC"
    } else {
        for image in peer.profileImageRepresentations {
            if let resource = image.resource as? CloudPeerPhotoSizeMediaResource { dc = resource.datacenterId }
            else if let resource = image.resource as? CloudPhotoSizeMediaResource { dc = resource.datacenterId }
            else if let resource = image.resource as? CloudFileMediaResource { dc = resource.datacenterId }
            if let value = dc, value > 0 { source = "Avatar DC"; break }
        }
    }
    if let value = dc, value <= 0 { dc = nil; source = nil }
    return ExteralessIdentityMetadata(id: id, datacenterId: dc, datacenterSource: source,
        userLink: key.kind == .user ? "tg://user?id=\(key.id)" : nil)
}
