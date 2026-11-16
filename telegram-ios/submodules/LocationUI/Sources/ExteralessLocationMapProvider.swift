import ExteralessCore
import Foundation
import ImageIO
import MapKit
import UIKit

/// Keeps the existing picker, pins, selection, live locations and camera. Only
/// the basemap is replaced. MapKit's public coordinate contract stays WGS84.
final class ExteralessLocationMapProvider {
    private weak var mapView: MKMapView?
    private let policy: () -> MapPolicy
    private let tileLoader: @Sendable (URL, @escaping MapResourceCache.Completion) -> NetworkResolverCancellation
    private let namespace = "map-view:" + UUID().uuidString
    private let attribution = UIButton(type: .system)
    private var overlay: ExteralessOSMTileOverlay?
    private var observation: NSObjectProtocol?
    private var mapType = MKMapType.standard
    private var fallback = false
    private var size = CGSize.zero
    private var topInset: CGFloat = 0

    init(mapView: MKMapView, policy: @escaping () -> MapPolicy = { MapPolicy.current() },
         tileLoader: @escaping @Sendable (URL, @escaping MapResourceCache.Completion) -> NetworkResolverCancellation = {
             MapProviderHTTP.shared.fetch(url: $0, completion: $1)
         }) {
        self.mapView = mapView
        self.policy = policy
        self.tileLoader = tileLoader
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        configuration.baseForegroundColor = .darkGray
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 10, weight: .medium)
            return attributes
        }
        attribution.configuration = configuration
        attribution.titleLabel?.numberOfLines = 2
        attribution.backgroundColor = UIColor(white: 1, alpha: 0.9)
        attribution.layer.cornerRadius = 5
        attribution.addAction(UIAction { [weak self] _ in self?.openAttribution() }, for: .touchUpInside)
        mapView.addSubview(attribution)
        _ = MapPolicyRuntime.shared
        observation = NotificationCenter.default.addObserver(forName: MapPolicyRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.fallback = false
            self?.apply()
        }
    }

    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        overlay?.invalidate()
        MapResourceCache.shared.clear(namespace: namespace)
    }

    func update(mapType: MKMapType) { self.mapType = mapType; fallback = false; apply() }

    func updateLayout(size: CGSize, topInset: CGFloat) {
        self.size = size; self.topInset = topInset
        let available = max(40, size.width - 100)
        let fitted = attribution.sizeThatFits(CGSize(width: available, height: 42))
        attribution.frame = CGRect(x: 12, y: topInset + 14, width: min(available, fitted.width), height: max(24, min(42, fitted.height)))
        if let mapView { mapView.bringSubviewToFront(attribution) }
    }

    private func apply() {
        guard let mapView else { return }
        if let overlay { mapView.removeOverlay(overlay); overlay.invalidate(); self.overlay = nil }
        let policy = self.policy()
        let standard = mapType == .standard
        let title: String
        if policy.useOpenStreetMap && standard && !fallback {
            let overlay = ExteralessOSMTileOverlay(namespace: namespace, epoch: MapPolicyRuntime.shared.epoch, tileLoader: tileLoader)
            overlay.failed = { [weak self, weak overlay] in
                DispatchQueue.main.async {
                    guard let self, let overlay, self.overlay === overlay else { return }
                    self.fallback = true; self.apply()
                }
            }
            self.overlay = overlay
            mapView.addOverlay(overlay, level: .aboveRoads)
            title = "© OpenStreetMap contributors"
        } else if policy.useOpenStreetMap && !standard {
            title = mapType == .satellite || mapType == .satelliteFlyover ? "Apple Maps · Satellite\nOSM has standard tiles only" : "Apple Maps · Hybrid\nOSM has standard tiles only"
        } else {
            title = fallback ? "OSM unavailable · Apple Maps fallback" : "Apple Maps"
        }
        mapView.mapType = mapType
        var configuration = attribution.configuration ?? .plain()
        configuration.title = title
        attribution.configuration = configuration
        attribution.accessibilityLabel = title
        updateLayout(size: size, topInset: topInset)
    }

    private func openAttribution() {
        let url = overlay != nil ? "https://www.openstreetmap.org/copyright" : "https://www.apple.com/legal/internet-services/maps/"
        if let url = URL(string: url) { UIApplication.shared.open(url) }
    }
}

private final class ExteralessOSMTileOverlay: MKTileOverlay, @unchecked Sendable {
    private struct Pending {
        let completion: (Data?, Error?) -> Void
        var token: NetworkResolverCancellation?
    }
    private let lock = NSLock()
    private let namespace: String
    private let epoch: UInt64
    private let tileLoader: @Sendable (URL, @escaping MapResourceCache.Completion) -> NetworkResolverCancellation
    private var pending: [UUID: Pending] = [:]
    private var retired = false
    var failed: (() -> Void)?

    init(namespace: String, epoch: UInt64,
         tileLoader: @escaping @Sendable (URL, @escaping MapResourceCache.Completion) -> NetworkResolverCancellation) {
        self.namespace = namespace; self.epoch = epoch
        self.tileLoader = tileLoader
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0; maximumZ = 19
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let url = MapProviderURL.openStreetMapTile(x: path.x, y: path.y, zoom: path.z) else { result(nil, MapResourceError.invalidRequest); return }
        let id = UUID()
        lock.lock()
        guard !retired else { lock.unlock(); result(nil, MapResourceError.cancelled); return }
        pending[id] = Pending(completion: result)
        lock.unlock()
        let key = MapResourceCache.Key(namespace: namespace, resource: "osm:\(epoch):\(path.z):\(path.x):\(path.y)")
        let token = MapResourceCache.shared.load(key: key, start: { [tileLoader] completion in tileLoader(url, completion) }, completion: { [weak self] value in
            guard let self else { return }
            self.lock.lock(); let pending = self.pending.removeValue(forKey: id); let retired = self.retired; self.lock.unlock()
            guard let pending, !retired else { return }
            if case let .success(resource) = value, let source = CGImageSourceCreateWithData(resource.data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width == 256, height == 256 {
                pending.completion(resource.data, nil)
            } else {
                pending.completion(nil, MapResourceError.unavailable)
                self.failed?()
            }
        })
        lock.lock(); let active = pending[id] != nil && !retired; if active { pending[id]?.token = token }; lock.unlock()
        if !active { token.cancel() }
    }

    func invalidate() {
        lock.lock(); retired = true; let pending = self.pending; self.pending.removeAll(); lock.unlock()
        for value in pending.values { value.token?.cancel(); value.completion(nil, MapResourceError.cancelled) }
    }
}
