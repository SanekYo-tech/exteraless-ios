import AccountContext
import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// The same two 8x8 owned PNG inputs as the Avatar native regressions. These are
/// media resources consumed by production UIKit, never expected-output pictures.
enum ClientHarnessLocalImages {
    static let redId: Int64 = 9_200_001
    static let greenId: Int64 = 9_200_002
    static let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGN4p2CCFTEMLQkAoxlQgUcPF4kAAAAASUVORK5CYII=")!
    static let green = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGOQvBSAFTEMLQkAt8pOwaU/RqkAAAAASUVORK5CYII=")!

    static func resource(_ id: Int64) -> LocalFileMediaResource {
        precondition(id == self.redId || id == self.greenId, "client-ui-harness: unknown local image")
        return LocalFileMediaResource(fileId: id, size: Int64(self.red.count))
    }

    static func data(_ id: Int64) -> Data {
        precondition(id == self.redId || id == self.greenId, "client-ui-harness: unknown local image bytes")
        return id == self.redId ? self.red : self.green
    }

    static func representation(_ id: Int64) -> TelegramMediaImageRepresentation {
        TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 8, height: 8), resource: self.resource(id),
            progressiveSizes: [], immediateThumbnailData: nil)
    }

    static func image(_ id: Int64) -> TelegramMediaImage {
        TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id),
            representations: [self.representation(id)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }

    @MainActor
    static func install(context: AccountContext) async throws {
        for id in [self.redId, self.greenId] {
            let resource = self.resource(id)
            context.account.postbox.mediaBox.storeResourceData(resource.id, data: self.data(id), synchronous: true)
            let status = try await clientHarnessFirst(context.account.postbox.mediaBox.resourceStatus(resource), name: "owned local PNG status")
            guard case .Local = status else { throw ClientHarnessFailure(description: "fixture PNG is not complete in the real MediaBox") }
            let stored = try await clientHarnessFirst(context.account.postbox.mediaBox.resourceData(resource,
                attemptSynchronously: true) |> filter { $0.complete }, name: "owned local PNG read-back")
            try clientHarnessRequire(try Data(contentsOf: URL(fileURLWithPath: stored.path)) == self.data(id), "local PNG read-back mismatch")
        }
    }
}
