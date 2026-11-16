import AccountContext
import Display
import Foundation
import SwiftSignalKit

/// Uses the installed native provider. No TelegramUI import, Postbox access,
/// class-name heuristics, credential values or synthetic navigation controller.
func exteralessSettingsSearchableItems(context: AccountContext) -> [SettingsSearchableItem] {
    MainActor.assumeIsolated {
        ExteralessSettingsSearchEntry.items(context: context).map { item in
            SettingsSearchableItem(id: item.ticket.storageID, title: item.title,
                alternate: item.terms + [item.explanation], icon: .appearance,
                breadcrumbs: ["Exteraless", item.section] + (item.unavailableReason.map { [$0] } ?? []),
                clientCopyLink: { MainActor.assumeIsolated { ExteralessSettingsSearchEntry.link(ticket: item.ticket, context: context)?.absoluteString } },
                present: { requestedContext, navigation, present in
                    MainActor.assumeIsolated {
                        guard requestedContext === context, let parent = navigation?.topViewController as? ViewController else { return }
                        present(.dismiss, nil)
                        _ = ExteralessSettingsSearchEntry.open(ticket: item.ticket, context: context, from: parent)
                    }
                })
        }
    }
}

func exteralessSettingsSearchUpdates(context: AccountContext, nativeItems: [SettingsSearchableItem]) -> Signal<[SettingsSearchableItem], NoError> {
    let updates = MainActor.assumeIsolated { ExteralessSettingsSearchEntry.updates }
    return updates |> deliverOnMainQueue |> map { _ in nativeItems + exteralessSettingsSearchableItems(context: context) }
}
