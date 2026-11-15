import Foundation
import SwiftSignalKit
import TelegramCore

public struct ChatArchiveSettings: Equatable, Codable {
    public var isHiddenByDefault: Bool
    public var hiddenPsaPeerId: EnginePeer.Id?
    /// Previous native row position while Exteraless's pull-to-open owns its
    /// initial hide. Optional so old files retain their meaning and encoding.
    public var exteralessArchivePullPrevious: Bool?
    
    public static var `default`: ChatArchiveSettings {
        return ChatArchiveSettings(isHiddenByDefault: false, hiddenPsaPeerId: nil)
    }
    
    public init(isHiddenByDefault: Bool, hiddenPsaPeerId: EnginePeer.Id?, exteralessArchivePullPrevious: Bool? = nil) {
        self.isHiddenByDefault = isHiddenByDefault
        self.hiddenPsaPeerId = hiddenPsaPeerId
        self.exteralessArchivePullPrevious = exteralessArchivePullPrevious
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.isHiddenByDefault = (try container.decode(Int32.self, forKey: "isHiddenByDefault")) != 0
        self.hiddenPsaPeerId = (try container.decodeIfPresent(Int64.self, forKey: "hiddenPsaPeerId")).flatMap(EnginePeer.Id.init)
        self.exteralessArchivePullPrevious = try container.decodeIfPresent(Bool.self, forKey: "exteralessArchivePullPrevious")
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.isHiddenByDefault ? 1 : 0) as Int32, forKey: "isHiddenByDefault")
        try container.encodeIfPresent(self.exteralessArchivePullPrevious, forKey: "exteralessArchivePullPrevious")
        if let hiddenPsaPeerId = self.hiddenPsaPeerId {
            try container.encode(hiddenPsaPeerId.toInt64(), forKey: "hiddenPsaPeerId")
        } else {
            try container.encodeNil(forKey: "hiddenPsaPeerId")
        }
    }

    public func withExteralessArchivePull(_ enabled: Bool) -> ChatArchiveSettings {
        var result = self
        if enabled {
            if result.exteralessArchivePullPrevious == nil {
                result.exteralessArchivePullPrevious = result.isHiddenByDefault
                result.isHiddenByDefault = true
            }
        } else if let previous = result.exteralessArchivePullPrevious {
            // A later explicit native Unhide wins over this presentation lease.
            if result.isHiddenByDefault { result.isHiddenByDefault = previous }
            result.exteralessArchivePullPrevious = nil
        }
        return result
    }
}

public func updateChatArchiveSettings(engine: TelegramEngine, _ f: @escaping (ChatArchiveSettings) -> ChatArchiveSettings) -> Signal<Never, NoError> {
    return engine.preferences.update(id: ApplicationSpecificPreferencesKeys.chatArchiveSettings, { entry in
        let currentSettings: ChatArchiveSettings
        if let entry = entry?.get(ChatArchiveSettings.self) {
            currentSettings = entry
        } else {
            currentSettings = .default
        }
        let updatedSettings = f(currentSettings)
        if updatedSettings == currentSettings { return entry }
        return SharedPreferencesEntry(updatedSettings)
    })
}
