import ExteralessCore
import Foundation

public func exteralessZalgoDisplayText(_ text: String) -> String {
    FilteringTextPolicy.displayedText(text, enabled: ClientSettings.shared.bool("privacy.zalgoFilter"))
}

public func exteralessZalgoDisplayText(_ text: NSAttributedString) -> NSAttributedString {
    FilteringTextPolicy.displayedText(text, enabled: ClientSettings.shared.bool("privacy.zalgoFilter"))
}
