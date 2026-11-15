import Display
import ExteralessCore
import SwiftSignalKit
import UIKit
import WebKit

/// Holds the live WebKit gesture preference for the lifetime of a browser page.
final class ExteralessBrowserGestures {
    private var observation: ClientSettingsObservation?

    /// The modal container reads its own Boolean gate, independently of the
    /// horizontal-navigation predicate used by the browser's root view.
    init(navigationView: UIView, settings: ClientSettings = .shared) {
        navigationView.disablesInteractiveTransitionGestureRecognizerNow = {
            settings.bool("chats.disableInAppBrowserGestures")
        }
        navigationView.disablesInteractiveModalDismiss = settings.bool("chats.disableInAppBrowserGestures")
        self.observation = settings.observe { [weak navigationView] keys in
            guard keys.isEmpty || keys.contains("chats.disableInAppBrowserGestures") else { return }
            Queue.mainQueue().async {
                navigationView?.disablesInteractiveModalDismiss = settings.bool("chats.disableInAppBrowserGestures")
            }
        }
    }

    init(webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = !ClientSettings.shared.bool("chats.disableInAppBrowserGestures")
        self.observation = ClientSettings.shared.observe { [weak webView] keys in
            guard keys.isEmpty || keys.contains("chats.disableInAppBrowserGestures") else { return }
            Queue.mainQueue().async {
                webView?.allowsBackForwardNavigationGestures = !ClientSettings.shared.bool("chats.disableInAppBrowserGestures")
            }
        }
    }
}
