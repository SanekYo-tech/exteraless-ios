import Foundation

public struct ChatLayoutRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
}

public enum ChatStickerLayoutPolicy {
    public static func radius(shape: Int, messageRadius: Double, isSticker: Bool) -> Double {
        guard isSticker else { return 0 }
        switch shape {
        case 1: return 6
        case 2: return messageRadius.isFinite ? max(0, messageRadius) : 0
        default: return 0
        }
    }

    /// Time and share move as one horizontal row only when the complete row fits the viewport.
    /// Names/reply previews overlapping the time's vertical band push it farther from the sticker.
    public static func timeFrames(sticker: ChatLayoutRect, time: ChatLayoutRect, share: ChatLayoutRect?, obstacles: [ChatLayoutRect], incoming: Bool, left: Double, right: Double, enabled: Bool) -> (time: ChatLayoutRect, share: ChatLayoutRect?) {
        guard enabled, sticker.isValid, time.isValid, left.isFinite, right.isFinite, right > left else { return (time, share) }
        var result = time
        result.x = incoming ? sticker.maxX + 8 : sticker.x - 8 - time.width
        for obstacle in obstacles where obstacle.isValid && obstacle.y < time.maxY && obstacle.maxY > time.y {
            if incoming { result.x = max(result.x, obstacle.maxX + 8) }
            else { result.x = min(result.x, obstacle.x - 8 - time.width) }
        }
        var resultShare = share
        if var value = share {
            guard value.isValid else { return (time, share) }
            value.x = incoming ? result.maxX + 8 : result.x - 8 - value.width
            resultShare = value
        }
        let lower = min(result.x, resultShare?.x ?? result.x)
        let upper = max(result.maxX, resultShare?.maxX ?? result.maxX)
        guard lower >= left + 8, upper <= right - 8 else { return (time, share) }
        return (result, resultShare)
    }
}
