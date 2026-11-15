import AccountContext
import Display
import SwiftSignalKit
import TelegramPermissionsUI
import TelegramPresentationData

/// Use the same native intro → creation flow as ComposeController. iOS presents
/// this introduction per entry; no inert Android `channel_intro` marker is stored.
func exteralessChannelCreationController(context: AccountContext) -> ViewController {
    let data = context.sharedContext.currentPresentationData.with { $0 }
    let controller = PermissionController(context: context, splashScreen: true)
    controller.setState(.custom(icon: .animation("Channel"), title: data.strings.ChannelIntro_Title, subtitle: nil, text: data.strings.ChannelIntro_Text, buttonTitle: data.strings.ChannelIntro_CreateChannel, secondaryButtonTitle: nil, footerText: nil), animated: false)
    controller.proceed = { [weak controller] _ in
        guard ExteralessAppearanceEntry.isMainMenuAvailable(context: context), let controller,
              let navigation = controller.navigationController as? NavigationController else { return }
        navigation.replaceTopController(createChannelController(context: context), animated: true)
    }
    return controller
}
