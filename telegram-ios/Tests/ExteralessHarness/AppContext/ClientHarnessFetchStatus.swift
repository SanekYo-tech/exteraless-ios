import AccountContext
import Foundation
import Postbox
import RangeSet
import SwiftSignalKit
import TelegramCore

/// PhotoResources.chatMessagePhotoStatus requires FetchManager even for a fully
/// cached local image. Only that read is supplied, backed by the real MediaBox.
/// No optimistic .Local value, downloader, request queue or media fetch is used.
final class ClientHarnessFetchStatus: FetchManager {
    private let postbox: Postbox
    let queue = Queue(name: "ClientHarness.LocalFetchStatus")
    init(postbox: Postbox) { self.postbox = postbox }

    func fetchStatus(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey,
        resource: EngineRawMediaResource) -> Signal<EngineMediaResourceStatus, NoError> {
        guard let resource = resource as? LocalFileMediaResource, resource.fileId == 9_100_001 else {
            fatalError("client-ui-harness: FetchManager only provides the owned Feed PNG status")
        }
        return self.postbox.mediaBox.resourceStatus(resource)
    }
    func interactivelyFetched(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey,
        mediaReference: AnyMediaReference?, resourceReference: MediaResourceReference, ranges: RangeSet<Int64>,
        statsCategory: MediaResourceStatsCategory, elevatedPriority: Bool, userInitiated: Bool,
        priority: FetchManagerPriority, storeToDownloadsPeerId: EnginePeer.Id?) -> Signal<Void, NoError> {
        fatalError("client-ui-harness: FetchManager.interactivelyFetched is not provided")
    }
    func cancelInteractiveFetches(category: FetchManagerCategory, location: FetchManagerLocation,
        locationKey: FetchManagerLocationKey, resource: EngineRawMediaResource) {
        fatalError("client-ui-harness: FetchManager.cancelInteractiveFetches is not provided")
    }
    func cancelInteractiveFetches(resourceId: String) { fatalError("client-ui-harness: FetchManager.cancelInteractiveFetches is not provided") }
    func toggleInteractiveFetchPaused(resourceId: String, isPaused: Bool) { fatalError("client-ui-harness: FetchManager.toggleInteractiveFetchPaused is not provided") }
    func raisePriority(resourceId: String) { fatalError("client-ui-harness: FetchManager.raisePriority is not provided") }
}
