import Foundation

public enum AppearanceSnowPolicy {
    public struct Particle: Equatable, Sendable {
        public let xFraction: Double
        public let sway: Double
        public let radius: Double
        public let duration: Double
        public let phase: Double
    }

    /// Stable finite particles, never a birth-rate accumulator. A tall window
    /// cannot allocate beyond the requested hard cap (itself limited to 32).
    public static func particles(width: Double, height: Double, maximum: Int, reducedMotion: Bool, lowPower: Bool) -> [Particle] {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              !reducedMotion, !lowPower else { return [] }
        let cap = max(0, min(32, maximum))
        let area = min(4096, width) * min(4096, height)
        let count = min(cap, max(4, Int(area / 16000) + 4))
        return (0..<count).map { i in
            let n = Double((i * 73 + 29) % 101) / 101
            return Particle(xFraction: n, sway: Double((i * 17) % 19) - 9,
                            radius: 1.0 + Double(i % 3) * 0.4,
                            duration: 6.0 + Double((i * 7) % 9),
                            phase: Double((i * 31 + 11) % 97) / 97)
        }
    }
}
