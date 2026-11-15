import Foundation

public struct PlayerStylePolicy: Equatable, Sendable {
    public enum Cover: Int, Sendable { case card, wide, full, disc }
    public enum Block: Int, CaseIterable, Sendable { case progress, controls, actions }
    public enum Background: Int, Sendable { case solid, gradient, blur }
    public enum MiniCover: Int, Sendable { case rounded, circle, hidden }
    public enum MiniShape: Int, Sendable { case rounded, pill, square }
    public enum MiniProgress: Int, Sendable { case ring, line, hidden, border }

    public let modernPlayer: Bool
    public let modernMiniPlayer: Bool
    public let profileMusicCard: Bool
    public let onlineLyrics: Bool
    public let cover: Cover
    public let coverScale: Double
    public let coverRadius: Double
    public let discSpin: Bool
    public let coverSwipe: Bool
    public let coverExtend: Bool
    public let titleCentered: Bool
    public let titleSize: Int
    public let titleAbove: Bool
    public let order: [Block]
    public let showActions: Bool
    public let showModes: Bool
    public let showLike: Bool
    public let showSource: Bool
    public let wavy: Bool
    public let controlsScale: Double
    public let actionsIsland: Bool
    public let themeColors: Bool
    public let background: Background
    public let miniCover: MiniCover
    public let miniShape: MiniShape
    public let miniProgress: MiniProgress
    public let miniThemeColors: Bool
    public let miniCompact: Bool
    public let miniArtist: Bool
    public let miniPrevious: Bool
    public let miniNext: Bool
    public let miniClose: Bool
    public let miniTop: Bool

    public static var current: Self { Self(values: ClientSettings.shared.snapshot()) }

    public init(values: [String: ClientSettingValue] = [:]) {
        func flag(_ field: String, _ fallback: Bool) -> Bool {
            if case let .bool(value) = values["appearance." + field] { return value }
            return fallback
        }
        func integer(_ field: String, _ fallback: Int) -> Int {
            if case let .integer(value) = values["appearance." + field], let result = Int(exactly: value) { return result }
            return fallback
        }
        self.modernPlayer = flag("md3Player", true)
        self.modernMiniPlayer = flag("md3MiniPlayer", true)
        self.profileMusicCard = flag("profileMusicCard", true)
        self.onlineLyrics = flag("lrclibAllowed", false)
        self.cover = Cover(rawValue: integer("playerCoverStyle", 0)) ?? .card
        self.coverScale = Double(min(100, max(60, integer("playerCoverSize", 100)))) / 100
        self.coverRadius = Double(min(48, max(0, integer("playerCoverRadius", 28))))
        self.discSpin = flag("playerDiscSpin", true)
        self.coverSwipe = flag("playerCoverSwipe", true) && (self.cover == .card || self.cover == .disc)
        self.coverExtend = flag("playerCoverExtend", true)
        self.titleCentered = integer("playerTitleAlign", 0) == 1
        self.titleSize = min(2, max(0, integer("playerTitleSize", 1)))
        self.titleAbove = flag("playerTitleAbove", false) && (self.cover == .card || self.cover == .disc)
        let rawOrder: String
        if case let .string(value) = values["appearance.playerOrder"] { rawOrder = value } else { rawOrder = "" }
        self.order = Self.blockOrder(rawOrder)
        self.showActions = flag("playerShowActions", true)
        self.showModes = flag("playerShowModes", true)
        self.showLike = flag("playerShowLike", true)
        self.showSource = flag("playerShowSource", true)
        self.wavy = flag("playerWavy", true)
        switch integer("playerControlsSize", 1) {
        case 0: self.controlsScale = 0.84
        case 2: self.controlsScale = 1.14
        default: self.controlsScale = 1
        }
        self.actionsIsland = integer("playerActionsStyle", 0) == 1
        self.themeColors = integer("playerColors", 0) == 1
        self.background = Background(rawValue: integer("playerBackground", 0)) ?? .solid
        self.miniCover = MiniCover(rawValue: integer("playerMiniCover", 0)) ?? .rounded
        self.miniShape = MiniShape(rawValue: integer("playerMiniShape", 0)) ?? .rounded
        self.miniProgress = MiniProgress(rawValue: integer("playerMiniProgress", 0)) ?? .ring
        self.miniThemeColors = integer("playerMiniColors", 1) != 0
        self.miniCompact = flag("playerMiniCompact", false)
        self.miniArtist = flag("playerMiniArtist", true)
        self.miniPrevious = flag("playerMiniPrevious", false)
        self.miniNext = flag("playerMiniNext", true)
        self.miniClose = flag("playerMiniClose", true)
        self.miniTop = flag("playerMiniTop", false)
    }

    public static func blockOrder(_ value: String) -> [Block] {
        var result: [Block] = []
        for part in value.prefix(128).split(separator: ",") {
            if let raw = Int(part.trimmingCharacters(in: .whitespaces)), let block = Block(rawValue: raw), !result.contains(block) { result.append(block) }
        }
        for block in Block.allCases where !result.contains(block) { result.append(block) }
        return result
    }

    public func rotatesDisc(playing: Bool, visible: Bool, reduceMotion: Bool) -> Bool {
        self.cover == .disc && self.discSpin && playing && visible && !reduceMotion
    }

    public func showsProfileMusic(hasMusic: Bool, isSettings: Bool) -> Bool {
        self.profileMusicCard && hasMusic && !isSettings
    }
}

/// SharedMediaPlayer's timestamp uses the monotonic media clock. Buffering and
/// pause do not advance; UI interpolation never changes playback or stored state.
public enum PlayerTimelinePolicy {
    public static func position(timestamp: Double, generationTimestamp: Double, now: Double, duration: Double, rate: Double, advancing: Bool) -> Double {
        guard timestamp.isFinite, duration.isFinite, duration > 0 else { return 0 }
        var value = timestamp
        if advancing, generationTimestamp.isFinite, generationTimestamp > 0, now.isFinite, rate.isFinite, rate > 0 {
            value += max(0, now - generationTimestamp) * rate
        }
        return min(duration, max(0, value))
    }
}

/// No Android ExoPlayer decoder preference is offered as a successful no-op.
public enum PlayerDecoderPolicy {
    public static let explanation = "Telegram chooses its native AVFoundation/VideoToolbox and FFmpeg-backed media pipelines for the resource and codec. Android ExoPlayer decoder priorities and extractors are not iOS APIs."
}

public enum PlayerVideoGesturePolicy {
    public static func entersPictureInPicture(enabled: Bool, downward: Bool, supported: Bool, isViewOnce: Bool, isAnimated: Bool) -> Bool {
        enabled && downward && supported && !isViewOnce && !isAnimated
    }
}
