#if EXTERALESS_MAP_ATTRIBUTION_FIXTURE
import CryptoKit
import ExteralessCore
import Foundation
import ImageIO
import MapKit
import SwiftSignalKit
import UIKit

private struct MapAttributionFailure: Error, CustomStringConvertible {
    let description: String
}

private func mapAttributionRequire(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw MapAttributionFailure(description: message) }
}

private func mapAttributionHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The cache calls this loader on its own queue. It has no HTTP/session fallback.
private final class MapAttributionOwnedLoader: @unchecked Sendable {
    struct Snapshot: Sendable {
        var successes = 0
        var failures = 0
        var rendererRequests = 0
        var invalidRequests = 0
        var closed = false
        var lastFailureWallTime: TimeInterval = 0
    }
    private let lock = NSLock()
    private let data: Data
    private var failurePath: String?
    private var state = Snapshot()

    init(data: Data) { self.data = data }
    var snapshot: Snapshot { self.lock.lock(); defer { self.lock.unlock() }; return self.state }
    func fail(path: String) { self.lock.lock(); self.failurePath = path; self.lock.unlock() }
    func close() { self.lock.lock(); self.state.closed = true; self.lock.unlock() }

    func fetch(_ url: URL, completion: @escaping MapResourceCache.Completion) -> NetworkResolverCancellation {
        let parts = url.path.split(separator: "/")
        let valid = url.scheme == "https" && url.host == "tile.openstreetmap.org"
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil
            && parts.count == 3 && Int(parts[0]) != nil && Int(parts[1]) != nil && parts[2].hasSuffix(".png")
        self.lock.lock()
        let value: Result<MapResourceData, MapResourceError>
        if self.state.closed {
            value = .failure(.cancelled)
        } else if !valid {
            self.state.invalidRequests += 1
            value = .failure(.invalidRequest)
        } else if url.path == self.failurePath {
            self.state.failures += 1
            self.state.lastFailureWallTime = Date().timeIntervalSince1970
            value = .failure(.unavailable)
        } else {
            self.state.successes += 1
            // z=0 is the explicit successful read. z=19/x=0 or 1/y=0 are
            // explicit failure reads, outside the fixed equatorial viewport.
            if url.path != "/0/0/0.png" { self.state.rendererRequests += 1 }
            value = .success(MapResourceData(data: self.data, ttl: 0))
        }
        self.lock.unlock()
        completion(value)
        return NetworkResolverCancellation()
    }
}

private final class MapAttributionTileReply: @unchecked Sendable {
    struct Snapshot: Sendable {
        var calls = 0
        var bytes = 0
        var sha256 = ""
        var error = ""
        var wallTime: TimeInterval = 0
    }
    private let lock = NSLock()
    private var state = Snapshot()
    var snapshot: Snapshot { self.lock.lock(); defer { self.lock.unlock() }; return self.state }
    func receive(_ data: Data?, _ error: Error?) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.state.calls += 1
        self.state.bytes = data?.count ?? 0
        self.state.sha256 = data.map(mapAttributionHash) ?? ""
        self.state.error = (error as? MapResourceError)?.rawValue ?? (error == nil ? "" : String(describing: error!))
        self.state.wallTime = Date().timeIntervalSince1970
    }
}

@MainActor
private final class MapAttributionRendererDelegate: NSObject, MKMapViewDelegate {
    var tileRenderers = 0
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let tiles = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
        self.tileRenderers += 1
        return MKTileOverlayRenderer(tileOverlay: tiles)
    }
}

/// Given-host witness for the production provider. LocationMapNode normally
/// owns it, but also enables live user location; this entry supplies an ordinary
/// MKMapView directly, using the same update(mapType:)/updateLayout APIs.
@MainActor
public enum ExteralessMapAttributionFixture {
    public static let requiredSources = [
        "telegram-ios/submodules/LocationUI/BUILD",
        "telegram-ios/submodules/LocationUI/Sources/ExteralessLocationMapProvider.swift",
        "telegram-ios/submodules/LocationUI/Sources/LocationMapNode.swift",
        "telegram-ios/submodules/LocationUI/Sources/Tests/ExteralessMapAttributionFixture.swift",
        "telegram-ios/Tests/ExteralessHarness/BUILD",
        "telegram-ios/Tests/ExteralessHarness/Info.plist",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenario.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessApplication.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessMapAttribution.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessVisualArtifacts.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessDomainEvidence.swift",
        "telegram-ios/Tests/ExteralessHarness/Tools/map_tile_fixture.py",
        "telegram-ios/Tests/ExteralessHarness/Fixtures/map-attribution-grid.png",
        "swift/ExteralessCore/BUILD.bazel",
        "swift/ExteralessCore/Sources/ExteralessCore/MapPolicy.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/MapPolicyRuntime.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/MapProviderHTTP.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/MapResourceCache.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/NetworkResolverHTTP.swift",
    ]
    public static let tileSource = "telegram-ios/Tests/ExteralessHarness/Fixtures/map-attribution-grid.png"
    public static let networkBoundary: [String: Any] = [
        "osmTransport": "injected owned 256px PNG or MapResourceError.unavailable only",
        "mapKitTransport": "standard public Apple/GeoServices map requests permitted",
        "mapKitTrafficMeasurement": "not intercepted; no total-egress-isolation claim",
        "locationPermissions": "not requested", "liveUserLocation": false,
        "accountRPC": "not invoked by this fixture", "foreignPlugins": "not loaded",
    ]

    private static func wait(until deadline: TimeInterval, _ description: String, _ ready: () -> Bool) async throws {
        while !ready() {
            try mapAttributionRequire(ProcessInfo.processInfo.systemUptime < deadline, "Map fixture timed out: " + description)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try mapAttributionRequire(ProcessInfo.processInfo.systemUptime < deadline, "Map fixture deadline: " + description)
    }

    private static func installedTile(_ mapView: MKMapView) throws -> MKTileOverlay {
        let overlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        try mapAttributionRequire(overlays.count == 1, "The production provider did not install exactly one tile overlay")
        return overlays[0]
    }

    /// Invokes the actual installed override, including cache, image validation,
    /// completion, failed callback and the provider's main-queue apply().
    private static func readTile(_ overlay: MKTileOverlay, path: MKTileOverlayPath) -> MapAttributionTileReply {
        let reply = MapAttributionTileReply()
        overlay.loadTile(at: path) { data, error in reply.receive(data, error) }
        return reply
    }

    private static func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }

    private static func observe(_ button: UIButton, mapView: MKMapView, hostView: UIView,
                                topPadding: CGFloat, inset: CGFloat, title: String) throws -> [String: Any] {
        guard let window = hostView.window, button.superview === mapView, mapView.superview === hostView,
              button.window === window, let configuration = button.configuration, let label = button.titleLabel else {
            throw MapAttributionFailure(description: "Missing actual provider button/label or given-host parent")
        }
        let rendered = label.attributedText?.string ?? label.text ?? ""
        let attributeFont = label.attributedText.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil }
        let font = attributeFont ?? label.font!
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        let content = configuration.contentInsets
        let local = button.frame
        let labelLocal = label.convert(label.bounds, to: button)
        let fitted = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        let global = button.convert(button.bounds, to: window)
        try mapAttributionRequire(configuration.title == title && rendered == title && button.accessibilityLabel == title,
            "Native configuration and rendered attribution UILabel differ")
        try mapAttributionRequire(button.buttonType == .system && !button.isHidden && button.alpha > 0.99
            && !label.isHidden && label.alpha > 0.99 && button.isEnabled && button.isUserInteractionEnabled,
            "Attribution is not a visible, enabled production system button")
        try mapAttributionRequire(content.top == 4 && content.leading == 6 && content.bottom == 4 && content.trailing == 6
            && configuration.titleLineBreakMode == .byWordWrapping && label.numberOfLines == 2
            && abs(font.pointSize - 10) < 0.01 && abs(weight - Double(UIFont.Weight.medium.rawValue)) < 0.02,
            "Production attribution font/wrapping/insets changed")
        try mapAttributionRequire(abs(local.minX - 12) < 0.5 && abs(local.minY - (topPadding + inset + 14)) < 0.5
            && local.width > 0 && local.width <= max(40, mapView.bounds.width - 100) + 0.5
            && (24...42).contains(local.height) && mapView.bounds.contains(local) && window.bounds.contains(global)
            && button.bounds.insetBy(dx: -0.5, dy: -0.5).contains(labelLocal)
            && labelLocal.width > 0 && labelLocal.height > 0 && fitted.height <= label.bounds.height + 1,
            "Actual attribution layout/label is clipped or shifted from the provider axes")
        try mapAttributionRequire(mapView.transform == .identity && button.transform == .identity
            && mapView.subviews.last === button && !mapView.showsUserLocation && mapView.userTrackingMode == .none,
            "Map fixture lost its real parent/z-order or disabled-user-location boundary")
        return ["nativeClass": NSStringFromClass(type(of: button)), "buttonType": button.buttonType.rawValue,
            "title": configuration.title ?? "", "label": rendered, "accessibilityLabel": button.accessibilityLabel ?? "",
            "insets": [content.top, content.leading, content.bottom, content.trailing], "lines": label.numberOfLines,
            "lineBreak": configuration.titleLineBreakMode.rawValue, "font": font.fontName,
            "pointSize": font.pointSize, "fontWeight": weight, "labelFittedHeight": fitted.height,
            "buttonFrameInMap": rect(local), "labelFrameInButton": rect(labelLocal),
            "buttonFrameInHost": rect(button.convert(button.bounds, to: hostView)), "buttonFrameInWindow": rect(global),
            "mapFrameInHost": rect(mapView.frame), "mapBounds": rect(mapView.bounds), "hostBounds": rect(hostView.bounds),
            "hostFrameInWindow": rect(hostView.convert(hostView.bounds, to: window)),
            "topPadding": topPadding, "inset": inset, "topInset": topPadding + inset,
            "directMapParent": true, "directHostParent": true, "frontmost": true, "identityTransforms": true,
            "inWindow": true, "enabled": button.isEnabled]
    }

    public static func run(hostView: UIView, topPadding: CGFloat, inset: CGFloat, tileData: Data,
                           sourceHashes: [String: String], setPalette: (Bool) -> Void,
                           probe: (String, MKMapView, UIButton, [String: Any]) throws -> Void) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        let overallDeadline = start + 9
        try mapAttributionRequire(hostView.window != nil && hostView.bounds.width >= 240 && hostView.bounds.height >= 320,
            "Map fixture requires its actual laid-out host")
        try mapAttributionRequire(Self.requiredSources.allSatisfy { sourceHashes[$0]?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil },
            "Map source receipt is missing a compiled provider/fixture/input")
        try mapAttributionRequire(tileData.count > 0 && tileData.count <= 16384 && mapAttributionHash(tileData) == sourceHashes[Self.tileSource],
            "Bundled map tile differs from the compiled input hash")
        guard let image = CGImageSourceCreateWithData(tileData as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(image, 0, nil), pixels.width == 256, pixels.height == 256 else {
            throw MapAttributionFailure(description: "Owned tile input is not a decodable 256px PNG")
        }
        let originalDark = hostView.traitCollection.userInterfaceStyle == .dark
        let mapView = MKMapView(frame: hostView.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = false
        mapView.userTrackingMode = .none
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.showsCompass = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)), animated: false)
        let renderer = MapAttributionRendererDelegate()
        mapView.delegate = renderer
        let loader = MapAttributionOwnedLoader(data: tileData)
        let previousSubviews = Set(mapView.subviews.map(ObjectIdentifier.init))
        var provider: ExteralessLocationMapProvider? = ExteralessLocationMapProvider(mapView: mapView,
            policy: { MapPolicy(useOpenStreetMap: true) }, tileLoader: { url, completion in loader.fetch(url, completion: completion) })
        let providerWitness = provider.map(Weak.init)
        let added = mapView.subviews.filter { !previousSubviews.contains(ObjectIdentifier($0)) }.compactMap { $0 as? UIButton }
        try mapAttributionRequire(added.count == 1, "Provider must create its one actual attribution UIButton")
        let button = added[0]
        provider?.updateLayout(size: mapView.bounds.size, topInset: topPadding + inset)
        hostView.addSubview(mapView)
        defer {
            provider?.update(mapType: .satellite)
            provider = nil
            mapView.delegate = nil
            mapView.removeFromSuperview()
            loader.close()
            setPalette(originalDark)
        }
        var segments: [[String: Any]] = []
        for (index, palette) in ["light", "dark"].enumerated() {
            let segmentStart = ProcessInfo.processInfo.systemUptime
            let deadline = min(overallDeadline, segmentStart + 3.8)
            let before = loader.snapshot
            let beforeRenderers = renderer.tileRenderers
            setPalette(palette == "dark")
            mapView.overrideUserInterfaceStyle = palette == "dark" ? .dark : .light
            var events: [[String: Any]] = []

            @MainActor func capture(_ step: String, title: String, extra: [String: Any] = [:]) async throws {
                provider?.updateLayout(size: mapView.bounds.size, topInset: topPadding + inset)
                hostView.layoutIfNeeded()
                button.setNeedsUpdateConfiguration()
                button.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 120_000_000)
                try mapAttributionRequire(ProcessInfo.processInfo.systemUptime < deadline, "Map palette exceeded its 3.8s segment")
                provider?.updateLayout(size: mapView.bounds.size, topInset: topPadding + inset)
                button.layoutIfNeeded()
                let state = loader.snapshot
                var value = extra
                value["palette"] = palette
                value["step"] = step
                value["provider"] = "ExteralessLocationMapProvider"
                value["mapClass"] = NSStringFromClass(type(of: mapView))
                value["mapDark"] = mapView.traitCollection.userInterfaceStyle == .dark
                value["buttonDark"] = button.traitCollection.userInterfaceStyle == .dark
                value["mapType"] = mapView.mapType.rawValue
                value["center"] = [mapView.centerCoordinate.latitude, mapView.centerCoordinate.longitude]
                value["showsUserLocation"] = mapView.showsUserLocation
                value["trackingMode"] = mapView.userTrackingMode.rawValue
                value["overlayCount"] = mapView.overlays.count
                value["tileRendererCount"] = renderer.tileRenderers
                value["loaderSuccesses"] = state.successes
                value["loaderFailures"] = state.failures
                value["rendererRequests"] = state.rendererRequests
                value["configurationControl"] = try observe(button, mapView: mapView, hostView: hostView,
                    topPadding: topPadding, inset: inset, title: title)
                value["events"] = events
                try probe("map-" + palette + "-" + step, mapView, button, value)
                try mapAttributionRequire(ProcessInfo.processInfo.systemUptime < deadline, "Map native capture exceeded its segment")
            }

            events.append(["name": "standard-update", "wallTime": Date().timeIntervalSince1970])
            provider?.update(mapType: .standard)
            let standard = try installedTile(mapView)
            let success = readTile(standard, path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1))
            try await wait(until: min(deadline, ProcessInfo.processInfo.systemUptime + 1.2), "real OSM renderer/owned tile") {
                success.snapshot.calls > 0 && renderer.tileRenderers > beforeRenderers && loader.snapshot.rendererRequests > before.rendererRequests
            }
            let successfulReply = success.snapshot
            try mapAttributionRequire(successfulReply.calls == 1 && successfulReply.error.isEmpty
                && successfulReply.sha256 == sourceHashes[Self.tileSource] && successfulReply.bytes == tileData.count,
                "Real tile override did not deliver the owned PNG exactly once")
            events.append(["name": "owned-tile-reply", "wallTime": successfulReply.wallTime])
            try await capture("osm-standard", title: "© OpenStreetMap contributors", extra: [
                "tileReplyCalls": successfulReply.calls, "tileReplySHA256": successfulReply.sha256, "tileReplyBytes": successfulReply.bytes,
                "overlayClass": NSStringFromClass(type(of: standard)), "tileSize": [standard.tileSize.width, standard.tileSize.height],
                "canReplaceMapContent": standard.canReplaceMapContent])

            events = [["name": "satellite-update", "wallTime": Date().timeIntervalSince1970]]
            provider?.update(mapType: .satellite)
            try mapAttributionRequire(mapView.overlays.isEmpty, "Satellite retained the OSM overlay")
            try await capture("satellite", title: "Apple Maps · Satellite\nOSM has standard tiles only")

            // A different offscreen path for each palette avoids the cache's real
            // negative-TTL reuse, without clearing any shared/neighbor namespace.
            let failurePath = MKTileOverlayPath(x: index, y: 0, z: 19, contentScaleFactor: 1)
            loader.fail(path: "/19/\(index)/0.png")
            provider?.update(mapType: .standard)
            let failing = try installedTile(mapView)
            events = [["name": "overlay-failure-request", "wallTime": Date().timeIntervalSince1970]]
            let failed = readTile(failing, path: failurePath)
            try await wait(until: min(deadline, ProcessInfo.processInfo.systemUptime + 1.2), "production overlay failure -> attribution apply") {
                failed.snapshot.calls > 0 && mapView.overlays.isEmpty
                    && button.configuration?.title == "OSM unavailable · Apple Maps fallback"
            }
            let failedReply = failed.snapshot
            let failedLoad = loader.snapshot
            try mapAttributionRequire(failedReply.calls == 1 && failedReply.error == MapResourceError.unavailable.rawValue
                && failedReply.bytes == 0 && failedLoad.failures == before.failures + 1,
                "Fallback bypassed or duplicated the actual injected loader failure")
            events.append(["name": "owned-loader-unavailable", "wallTime": failedLoad.lastFailureWallTime])
            events.append(["name": "overlay-error-completion", "wallTime": failedReply.wallTime])
            events.append(["name": "provider-fallback-observed", "wallTime": Date().timeIntervalSince1970])
            try await capture("failure-fallback", title: "OSM unavailable · Apple Maps fallback", extra: [
                "failurePath": [failurePath.x, failurePath.y, failurePath.z], "tileReplyCalls": failedReply.calls,
                "tileReplyError": failedReply.error, "tileReplyBytes": failedReply.bytes,
                "failureRoute": "installed MKTileOverlay.loadTile -> owned loader -> failed -> provider.apply"])
            segments.append(["palette": palette, "seconds": ProcessInfo.processInfo.systemUptime - segmentStart])
        }
        provider = nil
        mapView.delegate = nil
        mapView.removeFromSuperview()
        loader.close()
        let final = loader.snapshot
        try mapAttributionRequire(providerWitness?.value == nil && final.failures == 2 && final.invalidRequests == 0
            && mapView.overlays.isEmpty && button.window == nil, "Map fixture failed scoped provider/overlay cleanup")
        try mapAttributionRequire(ProcessInfo.processInfo.systemUptime < overallDeadline, "Map fixture exceeded its 9s interaction cap")
        return ["completed": true, "fixture": "ExteralessMapAttributionFixture.run", "networkBoundary": networkBoundary,
            "requestedRegion": [0.0, 0.0, 0.04, 0.04], "tileSource": tileSource, "tileSHA256": mapAttributionHash(tileData),
            "tileBytes": tileData.count, "segmentDeadlineSeconds": 3.8, "interactionDeadlineSeconds": 9,
            "seconds": ProcessInfo.processInfo.systemUptime - start, "segments": segments,
            "loaderFailures": final.failures, "loaderSuccesses": final.successes, "invalidRequests": final.invalidRequests,
            "sources": Dictionary(uniqueKeysWithValues: requiredSources.map { ($0, sourceHashes[$0]!) }),
            "cleanup": ["providerReleased": providerWitness?.value == nil, "overlayCount": mapView.overlays.count,
                "mapDetached": mapView.superview == nil, "buttonDetached": button.window == nil,
                "delegateDetached": mapView.delegate == nil, "loaderClosed": final.closed]]
    }
}
#endif
