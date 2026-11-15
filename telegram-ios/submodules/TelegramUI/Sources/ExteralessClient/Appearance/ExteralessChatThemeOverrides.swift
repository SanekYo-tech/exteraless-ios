import ExteralessCore
import TelegramCore

/// Shared ChatController insertion is documented in docs/wave-2/appearance.md.
/// The definition is added with that insertion, so an unlinked control is never
/// registered. Explicit forced themes/wallpapers retain their native precedence.
func exteralessChatThemeOverrides(theme: ChatTheme?, wallpaper: TelegramWallpaper?) -> (theme: ChatTheme?, wallpaper: TelegramWallpaper?) {
    return AppearanceChatThemePolicy.resolve(enabled: ClientSettings.shared.bool("appearance.customThemes", default: true), theme: theme, wallpaper: wallpaper)
}
