import ExteralessCore
import Foundation
import ImageIO
import MapKit
import SwiftSignalKit
import UIKit

func exteralessMapSnapshotData(accountId: Int64, resource: MapSnapshotMediaResource, adjustedLatitude: Double) -> Signal<Data?, NoError> {
    return Signal { subscriber in
        let queue = DispatchQueue(label: "Exteraless.MapSnapshotSubscription", qos: .utility)
        let lifetime = NetworkResolverCancellation()
        let current = MetaDisposable()
        let generation = Atomic<UInt64>(value: 0)
        let update: @Sendable () -> Void = {
            queue.async {
                guard !lifetime.isCancelled else { return }
                let revision = generation.modify { $0 &+ 1 }
                current.set(nil)
                subscriber.putNext(nil)
                let policy = MapPolicy.current(), epoch = MapPolicyRuntime.shared.epoch
                let provider = policy.preview(for: resource.scope)
                let key = MapResourceCache.Key(namespace: "account:\(accountId)", resource: "snapshot:\(epoch):\(resource.scope.rawValue):\(provider.rawValue):\(resource.latitude):\(resource.longitude):\(resource.width)x\(resource.height)")
                let token = MapResourceCache.shared.load(key: key, start: { completion in
                    let operation = ExteralessMapSnapshotOperation(resource: resource, adjustedLatitude: adjustedLatitude, provider: provider, completion: completion)
                    return operation.start()
                }, completion: { result in
                    queue.async {
                        guard !lifetime.isCancelled, generation.with({ $0 }) == revision else { return }
                        switch result {
                        case let .success(resource): subscriber.putNext(resource.data)
                        case .failure:
                            subscriber.putNext(exteralessMapPlaceholder(width: Int(resource.width), height: Int(resource.height), label: provider == .disabled ? "Map previews disabled" : "Map unavailable"))
                        }
                    }
                })
                current.set(ActionDisposable { token.cancel() })
            }
        }
        _ = MapPolicyRuntime.shared
        let observer = NotificationCenter.default.addObserver(forName: MapPolicyRuntime.didChange, object: nil, queue: nil) { _ in update() }
        update()
        return ActionDisposable {
            lifetime.cancel(); current.dispose()
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private func exteralessMapPlaceholder(width: Int, height: Int, label: String) -> Data? {
    return exteralessMapLabelledImage(nil, width: width, height: height, label: label)
}

private func exteralessMapLabelledImage(_ image: UIImage?, width: Int, height: Int, label: String) -> Data? {
    guard (1...1024).contains(width), (1...1024).contains(height) else { return nil }
    let size = CGSize(width: CGFloat(width + 1), height: CGFloat(height + 10))
    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor(white: 0.91, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
        image?.draw(in: CGRect(origin: .zero, size: size))
        // Keep attribution readable and inside the eventual aspect-fill crop. For
        // Yandex, use a top label so the provider's own bottom logo stays visible.
        let font = UIFont.systemFont(ofSize: width < 130 ? 8 : 10, weight: .medium)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let labelRect = CGRect(x: 5, y: 10, width: size.width - 10, height: image == nil ? 34 : 19)
        UIColor(white: 1, alpha: 0.9).setFill(); context.fill(labelRect)
        (label as NSString).draw(in: labelRect.insetBy(dx: 3, dy: 2), withAttributes: [.font: font, .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraph])
    }
    return rendered.jpegData(compressionQuality: 0.9)
}

private final class ExteralessMapSnapshotOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let resource: MapSnapshotMediaResource
    private let adjustedLatitude: Double
    private let provider: MapPolicy.Preview
    private var completion: MapResourceCache.Completion?
    private var http: NetworkResolverCancellation?
    private var snapshotter: MKMapSnapshotter?
    private var cancelled = false

    init(resource: MapSnapshotMediaResource, adjustedLatitude: Double, provider: MapPolicy.Preview, completion: @escaping MapResourceCache.Completion) {
        self.resource = resource; self.adjustedLatitude = adjustedLatitude; self.provider = provider; self.completion = completion
    }

    func start() -> NetworkResolverCancellation {
        DispatchQueue.main.async { self.begin() }
        return NetworkResolverCancellation { self.cancel() }
    }

    private var active: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled && completion != nil }

    private func begin() {
        guard active else { return }
        guard (1...1024).contains(resource.width), (1...1024).contains(resource.height), let coordinate = MapCoordinate(latitude: resource.latitude, longitude: resource.longitude) else {
            finish(.failure(.invalidRequest)); return
        }
        if provider == .disabled {
            guard let data = exteralessMapPlaceholder(width: Int(resource.width), height: Int(resource.height), label: resource.width < 160 ? "Previews off" : "Map previews disabled") else { finish(.failure(.invalidImage)); return }
            finish(.success(.init(data: data, ttl: 300))); return
        }
        if provider == .yandex {
            let ratio = min(1, min(650 / Double(resource.width), 450 / Double(resource.height)))
            // Retain the existing preview's pin-tip/center offset, in WGS84.
            let center = MapCoordinate(latitude: adjustedLatitude, longitude: coordinate.longitude) ?? coordinate
            guard let url = MapProviderURL.yandexPreview(coordinate: center, width: max(1, Int(Double(resource.width) * ratio)), height: max(1, Int(Double(resource.height) * ratio)), language: Locale.current.languageCode ?? "en", apiKey: ClientSettings.shared.string("maps.yandexAPIKey")) else { native(fallback: true); return }
            let http = MapProviderHTTP.shared.fetch(url: url) { [weak self] result in
                guard let self, self.active else { return }
                if case let .success(resource) = result, let source = CGImageSourceCreateWithData(resource.data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                   (1...1300).contains(width), (1...900).contains(height), let image = UIImage(data: resource.data),
                   let data = exteralessMapLabelledImage(image, width: Int(self.resource.width), height: Int(self.resource.height), label: "Yandex Maps") {
                    self.finish(.success(.init(data: data, ttl: min(300, resource.ttl))))
                } else { DispatchQueue.main.async { self.native(fallback: true) } }
            }
            lock.lock(); let cancelled = self.cancelled; if !cancelled { self.http = http }; lock.unlock()
            if cancelled { http.cancel() }
        } else { native(fallback: false) }
    }

    private func native(fallback: Bool) {
        guard active else { return }
        let options = MKMapSnapshotter.Options()
        // MapKit accepts WGS84 and performs its own regional rendering conversion.
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: adjustedLatitude, longitude: resource.longitude), span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003))
        options.mapType = .standard; options.pointOfInterestFilter = .excludingAll; options.showsBuildings = true
        options.size = CGSize(width: CGFloat(resource.width) + 1, height: CGFloat(resource.height) + 10); options.scale = 2
        let snapshotter = MKMapSnapshotter(options: options)
        lock.lock(); let cancelled = self.cancelled; if !cancelled { self.snapshotter = snapshotter }; lock.unlock()
        guard !cancelled else { snapshotter.cancel(); return }
        snapshotter.start(with: DispatchQueue.global(qos: .utility)) { [weak self] result, _ in
            guard let self, self.active else { return }
            let label = fallback ? (self.resource.width < 160 ? "Apple · fallback" : "Yandex unavailable · Apple Maps") : "Apple Maps"
            guard let image = result?.image, let data = exteralessMapLabelledImage(image, width: Int(self.resource.width), height: Int(self.resource.height), label: label) else { self.finish(.failure(.unavailable)); return }
            self.finish(.success(.init(data: data, ttl: fallback ? 30 : 300)))
        }
    }

    private func finish(_ result: Result<MapResourceData, MapResourceError>) {
        lock.lock(); let completion = self.completion; self.completion = nil; lock.unlock()
        completion?(result)
    }
    private func cancel() {
        lock.lock(); cancelled = true; completion = nil; let http = self.http, snapshotter = self.snapshotter; self.http = nil; self.snapshotter = nil; lock.unlock()
        http?.cancel(); snapshotter?.cancel()
    }
}
