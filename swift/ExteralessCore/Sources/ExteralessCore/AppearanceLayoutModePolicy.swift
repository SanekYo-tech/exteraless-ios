import Foundation

/// Content layout only. Raw values match NekoConfig.TabletMode; no device,
/// orientation, size class or hardware capability is changed by this policy.
public enum AppearanceLayoutModePolicy {
    public static let settingKey = "appearance.tabletMode"

    /// Joined separately by the coordinator with the application-root binding.
    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(
            key: "appearance.tabletMode", title: "Content layout", section: "Appearance · Navigation",
            defaultValue: .integer(0), options: [
                ClientSettingOption(value: .integer(0), title: "Automatic"),
                ClientSettingOption(value: .integer(1), title: "Tablet layout · where it fits"),
                ClientSettingOption(value: .integer(2), title: "Phone layout · single pane")
            ], explanation: "Controls root navigation panes and navigation-managed sheets using the current window, safe areas and keyboard. Tablet mode falls back to one accessible pane in small windows. Hardware and system size classes stay native.",
            androidSymbols: ["NekoConfig.tabletMode", "AndroidUtilities.isTabletForce"]
        )
    ]

    public enum Mode: Int, CaseIterable, Sendable {
        case automatic = 0
        case tablet = 1
        case phone = 2
    }

    public struct Viewport: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var left: Double
        public var top: Double
        public var right: Double
        public var bottom: Double
        public var keyboardHeight: Double
        public var dividerX: Double?
        public var dividerWidth: Double
        public var allowsSheets: Bool

        public init(width: Double, height: Double, left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0, keyboardHeight: Double = 0, dividerX: Double? = nil, dividerWidth: Double = 0, allowsSheets: Bool = true) {
            self.width = width
            self.height = height
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
            self.keyboardHeight = keyboardHeight
            self.dividerX = dividerX
            self.dividerWidth = dividerWidth
            self.allowsSheets = allowsSheets
        }
    }

    public struct Rect: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    public enum Root: Equatable, Sendable {
        case stock
        case single
        case split(masterWidth: Double)
    }

    public struct Decision: Equatable, Sendable {
        public let root: Root
        public let largeModals: Bool
        public let sheetFrame: Rect?
    }

    public static let minimumMasterWidth: Double = 320
    public static let minimumDetailWidth: Double = 360
    public static let minimumVisibleHeight: Double = 180

    public static func resolve(mode: Mode, viewport: Viewport, hasMaster: Bool, hasMinimizedStack: Bool = false, preferredSheetWidth: Double? = nil, preferredSheetHeight: Double? = nil) -> Decision {
        guard mode != .automatic else { return Decision(root: .stock, largeModals: false, sheetFrame: nil) }
        guard mode == .tablet, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return Decision(root: .single, largeModals: false, sheetFrame: nil)
        }
        let width = viewport.width
        let height = viewport.height
        let left = min(width, nonnegative(viewport.left))
        let right = min(width - left, nonnegative(viewport.right))
        let top = min(height, nonnegative(viewport.top))
        let bottom = min(height - top, nonnegative(viewport.bottom))
        let visibleBottom = min(height - top, max(bottom, nonnegative(viewport.keyboardHeight)))
        let usableWidth = width - left - right
        let visibleHeight = height - top - visibleBottom

        var root = Root.single
        if hasMaster && !hasMinimizedStack && usableWidth >= minimumMasterWidth + minimumDetailWidth && visibleHeight >= minimumVisibleHeight {
            if let dividerX = viewport.dividerX {
                let halfGap = nonnegative(viewport.dividerWidth) * 0.5
                if dividerX.isFinite && dividerX - halfGap - left >= minimumMasterWidth && width - dividerX - halfGap - right >= minimumDetailWidth {
                    root = .split(masterWidth: dividerX)
                }
            } else {
                // Android's explicit left-pane rule is max(320dp, 35%); retain
                // a usable detail lane and the actual outer safe areas on iOS.
                let master = left + min(usableWidth - minimumDetailWidth, max(minimumMasterWidth, floor(usableWidth * 0.35)))
                root = .split(masterWidth: master)
            }
        }

        // Grouping is based on window space without the keyboard, so opening a
        // keyboard can make a sheet full-screen without moving it into the stack.
        let largeModals = viewport.allowsSheets && usableWidth >= 600 && height - top - bottom >= 600
        var sheetFrame: Rect?
        if largeModals && usableWidth >= 368 && visibleHeight >= 368 {
            let sheetWidth = min(usableWidth - 48, max(320, preferred(preferredSheetWidth, fallback: 540)))
            let sheetHeight = min(visibleHeight - 48, max(320, preferred(preferredSheetHeight, fallback: 720)))
            sheetFrame = Rect(x: left + floor((usableWidth - sheetWidth) * 0.5), y: top + floor((visibleHeight - sheetHeight) * 0.5), width: sheetWidth, height: sheetHeight)
        }
        return Decision(root: root, largeModals: largeModals, sheetFrame: sheetFrame)
    }

    private static func nonnegative(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    private static func preferred(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }
}
