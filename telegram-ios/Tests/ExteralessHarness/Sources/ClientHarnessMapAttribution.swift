import Display
import Foundation
import LocationUI
import UIKit

@MainActor
extension ClientHarnessSession {
    func runMapAttributionSupplement() async throws {
        try clientHarnessRequire(self.report.scenario == "map-attribution" && self.navigation.validLayout != nil,
            "Map attribution requires its explicit scene and actual host layout")
        try self.loadDomainSourceEvidence()
        guard let manifest = self.report.facts["domainSources"] as? [String: Any],
              let sources = manifest["files"] as? [String: String],
              let input = Bundle.main.url(forResource: "map-attribution-grid", withExtension: "png") else {
            throw ClientHarnessFailure(description: "Missing compiled map sources or owned tile resource")
        }
        let bytes = try Data(contentsOf: input)
        self.report.facts["buildSelection"] = ["bundle": "org.exteraless.ClientUIHarness",
            "target": "//Telegram:ClientUIHarness", "host": "same-client-ui-app"]
        let host: UIView = self.navigation.view
        let topPadding = host.safeAreaInsets.top
        let inset = (self.navigation.topViewController as? ViewController)?.navigationBar?.frame.height ?? 0
        let result = try await ExteralessMapAttributionFixture.run(hostView: host, topPadding: topPadding, inset: inset,
            tileData: bytes, sourceHashes: sources, setPalette: { self.setDark($0) }, probe: { name, map, button, payload in
                var payload = payload
                payload["mapInstance"] = self.viewIdentities.id(map)
                payload["buttonInstance"] = self.viewIdentities.id(button)
                payload["sourceManifestSHA256"] = manifest["sha256"]
                // The full native hierarchy and the actual provider UIButton are
                // separate captures. No tile input is used as an expected frame.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                var drawn = false
                let image = UIGraphicsImageRenderer(size: host.bounds.size, format: format).image { _ in
                    drawn = host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
                }
                try clientHarnessRequire(drawn, "Native MKMapView hierarchy capture did not complete")
                payload["nativeViewImage"] = try self.saveVisualImage(image, name: name, kind: "live-map-hierarchy")
                payload["nativeButtonImage"] = try self.saveVisualImage(clientHarnessViewImage(button),
                    name: name + "-button", kind: "actual-provider-button-layer")
                try self.probe(name, extra: payload)
            })
        self.report.facts["mapAttribution"] = result
        try clientHarnessRequire(self.window.findFirstResponder() == nil, "Map scene retained unexpected input")
        try self.visualProbe("map-cleanup", view: host, extra: ["nativeFixtureReturned": true,
            "firstResponder": false, "cleanup": result["cleanup"] ?? [:]])
    }
}
