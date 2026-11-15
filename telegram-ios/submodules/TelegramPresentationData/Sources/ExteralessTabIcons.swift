import AppBundle
import Foundation
import UIKit

private func exteralessTabAsset(_ item: UITabBarItem, selected: Bool) -> String? {
    if let name = exteralessAppBundleImageName(selected ? item.selectedImage : item.image) { return name }
    return exteralessAppBundleImageName(item.image)
}

public func exteralessTabIconOverride(_ item: UITabBarItem) -> UIImage? {
    return exteralessTabAsset(item, selected: false).flatMap { exteralessAppBundleImage($0) }
}

/// UITabBarItems retain their images across theme changes. Resolve from the named
/// asset again to restore originals after disabling/removing an icon pack.
public func exteralessResolvedTabIcon(_ item: UITabBarItem, selected: Bool = false) -> UIImage? {
    guard let name = exteralessTabAsset(item, selected: selected) else { return selected ? item.selectedImage : item.image }
    return exteralessAppBundleImage(name) ?? UIImage(named: name, in: getAppBundle(), compatibleWith: nil)
}
