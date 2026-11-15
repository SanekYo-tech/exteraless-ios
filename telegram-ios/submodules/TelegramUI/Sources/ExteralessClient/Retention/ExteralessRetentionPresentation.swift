import ExteralessCore
import Foundation
import TelegramCore
import UIKit

enum ExteralessRetentionPresentation {
    static func color(policy: RetentionPolicy, fallback: UIColor) -> UIColor {
        guard let argb = policy.deletedColorARGB else { return fallback }
        return UIColor(red: CGFloat((argb >> 16) & 255) / 255.0, green: CGFloat((argb >> 8) & 255) / 255.0, blue: CGFloat(argb & 255) / 255.0, alpha: CGFloat((argb >> 24) & 255) / 255.0)
    }

    static func mark(policy: RetentionPolicy, fallbackColor: UIColor, font: UIFont) -> NSAttributedString {
        let color = self.color(policy: policy, fallback: fallbackColor)
        if policy.useDeletedIcon, let image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: font.descender, width: font.lineHeight, height: font.lineHeight)
            return NSAttributedString(attachment: attachment)
        }
        return NSAttributedString(string: policy.deletedMark.isEmpty ? "deleted" : policy.deletedMark, attributes: [.foregroundColor: color, .font: font])
    }

    static func errorText(_ error: ExteralessRetentionError) -> String {
        switch error {
        case .unavailable: return "The account archive is unavailable or is being cleared."
        case .invalidArchive: return "The retained archive could not be read. Clear the archive to reset it."
        case .unsupportedFormat: return "This archive uses an unsupported format. It can be explicitly cleared."
        case .limitExceeded: return "The retention storage or export limit was reached."
        case .mediaUnavailable: return "This file was not received locally, or its retained copy has expired."
        case .mediaIO: return "The retained file could not be read or written."
        case .cancelled: return "The archive changed during this operation. Refresh and try again."
        }
    }

    static func editedMark(policy: RetentionPolicy, color: UIColor, font: UIFont) -> NSAttributedString {
        if policy.useEditedIcon, let image = UIImage(systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize)) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: font.descender, width: font.lineHeight, height: font.lineHeight)
            return NSAttributedString(attachment: attachment)
        }
        return NSAttributedString(string: policy.editedMark.isEmpty ? "edited" : policy.editedMark, attributes: [.font: font, .foregroundColor: color])
    }
}
