import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Decode the original resource rather than the SDR DrawingContext raster. The
/// image view stays under the gallery image node's zoom and capture-protection layer.
final class ExteralessHDRPhoto {
    private weak var parent: TransformImageNode?
    private let context: AccountContext
    private let resource: EngineMediaResource
    private let imageView = UIImageView()
    private let disposable = MetaDisposable()
    private var observation: ClientSettingsObservation?
    private var generation = UUID()

    init(context: AccountContext, resource: EngineMediaResource, parent: TransformImageNode) {
        self.context = context
        self.resource = resource
        self.parent = parent
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.imageView.isUserInteractionEnabled = false
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || keys.contains("chats.hdrPhotos") else { return }
            Queue.mainQueue().async { self?.reload() }
        }
        self.reload()
    }

    private func reload() {
        self.generation = UUID()
        let generation = self.generation
        self.disposable.set(nil)
        self.imageView.image = nil
        self.imageView.removeFromSuperview()
        guard #available(iOS 17.0, *), ClientSettings.shared.bool("chats.hdrPhotos", default: true) else { return }
        self.imageView.preferredImageDynamicRange = .high
        self.disposable.set((self.context.engine.resources.data(resource: self.resource)
        |> filter { $0.isComplete }
        |> take(1)
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { data -> UIImage? in
            var configuration = UIImageReader.Configuration()
            configuration.prefersHighDynamicRange = true
            configuration.preparesImagesForDisplay = true
            configuration.preferredThumbnailSize = CGSize(width: 4096.0, height: 4096.0)
            let image = UIImageReader(configuration: configuration).image(contentsOf: URL(fileURLWithPath: data.path))
            return image?.isHighDynamicRange == true ? image : nil
        }
        |> deliverOnMainQueue).start(next: { [weak self] image in
            guard let self, generation == self.generation, let parent = self.parent, let image,
                  ClientSettings.shared.bool("chats.hdrPhotos", default: true) else { return }
            self.imageView.image = image
            self.imageView.frame = parent.bounds
            parent.view.insertSubview(self.imageView, at: 0)
        }))
    }

    deinit {
        self.observation?.cancel()
        self.disposable.dispose()
        let imageView = self.imageView
        Queue.mainQueue().async { imageView.removeFromSuperview() }
    }
}
