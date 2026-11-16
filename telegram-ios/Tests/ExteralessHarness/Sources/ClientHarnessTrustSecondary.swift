import Display
import Foundation
import TelegramUI
import UIKit

@MainActor
private final class ClientHarnessTrustCapture {
    var finished = false
    var link = false
    weak var lastSheet: UIActivityViewController?
    var sheetCount = 0
    var error: Error?
}

@MainActor
extension ClientHarnessSession {
    func runTrustSecondarySupplement() async throws {
        guard self.report.scenario == "trust-secondary-permissions",
              let presenter = self.navigation.topViewController as? ViewController,
              presenter.view.window === self.window else {
            throw ClientHarnessFailure(description: "Secondary trust fixture requires its actual visible presenter")
        }
        try self.loadDomainSourceEvidence()
        self.report.facts["buildSelection"] = ["bundle": "org.exteraless.ClientUIHarness",
            "target": "//Telegram:ClientUIHarness", "host": "same-client-ui-app"]
        try self.visualProbe("trust-secondary-start", view: self.navigation.view,
            extra: ["fixture": "PluginTrustSecondaryUIFixture.run", "realPython": false])
        let capture = ClientHarnessTrustCapture()
        let sampler = Task { @MainActor in
            while !capture.finished && !Task.isCancelled {
                do {
                    if !capture.link {
                        let found = self.driver.views(in: self.window).contains { view in
                            guard view.window === self.window && !view.isHidden && view.alpha > 0.9 else { return false }
                            return (view as? UILabel)?.text == "Native link fixture"
                                || (view as? UITextView)?.text == "Native link fixture"
                                || view.accessibilityLabel == "Native link fixture"
                        }
                        if found {
                            capture.link = true
                            try self.visualProbe("trust-link-visible", view: self.window,
                                extra: ["observedText": "Native link fixture", "source": "actual uiPresent/openLink consumer"])
                        }
                    }
                    if let sheet = presenter.presentedViewController as? UIActivityViewController,
                       sheet.viewIfLoaded?.window === self.window, !sheet.isBeingDismissed {
                        if capture.link && sheet !== capture.lastSheet {
                            capture.lastSheet = sheet
                            capture.sheetCount += 1
                            let name = capture.sheetCount == 1 ? "trust-external-share-visible" : "trust-own-share-visible"
                            try clientHarnessRequire(capture.sheetCount <= 2, "Secondary fixture created an unexpected share sheet")
                            try self.visualProbe(name, view: self.window,
                                extra: ["controller": NSStringFromClass(type(of: sheet)), "nativeViewMounted": true])
                        }
                    }
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch is CancellationError { return }
                catch { capture.error = error; return }
            }
        }
        do {
            try await PluginTrustSecondaryUIFixture.run(context: self.context, presenter: presenter)
        } catch {
            capture.finished = true
            sampler.cancel()
            _ = await sampler.result
            throw error
        }
        capture.finished = true
        sampler.cancel()
        _ = await sampler.result
        if let error = capture.error { throw error }
        try clientHarnessRequire(capture.link && capture.sheetCount == 2,
            "Secondary trust operations returned without observed alert and both actual share sheets")
        try clientHarnessRequire(presenter.presentedViewController == nil && self.window.findFirstResponder() == nil,
            "Secondary trust fixture retained a presented surface or input")
        self.report.facts["trustSecondary"] = ["completed": true, "fixture": "PluginTrustSecondaryUIFixture.run",
            "transport": "canned Host worker/callbacks; real native UI consumers; no URL/network"]
        try self.visualProbe("trust-secondary-completed", view: self.navigation.view,
            extra: ["nativeFixtureReturned": true, "presentedController": false])
    }
}
