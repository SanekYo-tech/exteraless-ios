import ExteralessCore
import Foundation
import TelegramCore

public func exteralessFolderTitle(_ title: ChatFolderTitle, allChats: Bool) -> ChatFolderTitle {
    let mode = ClientSettings.shared.integer("appearance.tabsTitleType")
    guard mode != 0 else { return title }
    let value = AppearanceFolderPolicy.title(title.text, mode: mode, allChats: allChats)
    let entities = title.entities.compactMap { entity -> MessageTextEntity? in
        guard entity.range.lowerBound >= 0, entity.range.upperBound <= value.originalLimit else { return nil }
        return MessageTextEntity(range: (entity.range.lowerBound + value.entityOffset)..<(entity.range.upperBound + value.entityOffset), type: entity.type)
    }
    return ChatFolderTitle(text: value.text, entities: entities, enableAnimations: title.enableAnimations)
}
