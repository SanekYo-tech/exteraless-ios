import ExteralessCore
import Foundation
import UIKit

/// Recolors only the existing native dot's interior, preserving the row's
/// highlighted/pinned outline and the Appearance-owned marker geometry.
public func exteralessIdentityActivityImage(_ image: UIImage?, band: IdentityActivityBand?) -> UIImage? {
    guard let image, let band else { return image }
    let color: UIColor
    switch band {
    case .online: return image
    case .within15Minutes: color = UIColor(red: 234.0 / 255.0, green: 234.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    case .within30Minutes: color = UIColor(red: 234.0 / 255.0, green: 132.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    case .withinHour: color = UIColor(red: 234.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
        image.draw(at: .zero)
        color.setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: image.size).insetBy(dx: 2, dy: 2)).fill()
    }
}
