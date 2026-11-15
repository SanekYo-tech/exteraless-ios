import Foundation

public enum PillWeatherSource: String, Sendable { case telegram, openMeteo }

public struct PillWeatherReading: Equatable, Sendable {
    public let coordinate: PillCoordinate
    public let temperatureCelsius: Double
    public let emoji: String
    public let updatedAt: Date
    public let source: PillWeatherSource
    public init(coordinate: PillCoordinate, celsius: Double, emoji: String, updatedAt: Date, source: PillWeatherSource) throws {
        guard celsius.isFinite, (-150...100).contains(celsius), !emoji.isEmpty, emoji.count <= 32 else { throw PillError.invalidData }
        _ = try PillFreshness.milliseconds(updatedAt)
        self.coordinate = coordinate; temperatureCelsius = celsius; self.emoji = emoji; self.updatedAt = updatedAt; self.source = source
    }
    public func temperature(units: String, timeZone: TimeZone = .current) -> String {
        let fahrenheitZones = ["America/Nassau", "America/Belize", "America/Cayman", "Pacific/Palau"]
        let fahrenheit = units == "F" || (units == "AUTO" && (timeZone.identifier.hasPrefix("US/") || fahrenheitZones.contains(timeZone.identifier)))
        let value = fahrenheit ? temperatureCelsius * 9 / 5 + 32 : temperatureCelsius
        return "\(Int(value.rounded()))°\(fahrenheit ? "F" : "C")"
    }
    public static func parseOpenMeteo(_ data: Data, coordinate: PillCoordinate, now: Date) throws -> PillWeatherReading {
        struct Response: Decodable {
            struct Current: Decodable { let temperature: Double; let weathercode: Int; let is_day: Int? }
            struct Units: Decodable { let temperature: String }
            let current_weather: Current
            let current_weather_units: Units
        }
        guard data.count <= 262_144, let response = try? JSONDecoder().decode(Response.self, from: data) else { throw PillError.invalidData }
        let celsius: Double
        switch response.current_weather_units.temperature {
        case "°C": celsius = response.current_weather.temperature
        case "°F": celsius = (response.current_weather.temperature - 32) * 5 / 9
        default: throw PillError.invalidData
        }
        let emoji: String
        switch response.current_weather.weathercode {
        case 0: emoji = response.current_weather.is_day == 0 ? "🌙" : "☀️"
        case 1, 2: emoji = response.current_weather.is_day == 0 ? "🌙" : "⛅️"
        case 3: emoji = "☁️"
        case 45, 48: emoji = "🌫️"
        case 51, 53, 55, 61, 63, 65, 80, 81: emoji = "🌧️"
        case 56, 57, 66, 67, 71, 73, 75, 77, 85, 86: emoji = "🌨️"
        case 82, 95, 96, 99: emoji = "⛈️"
        default: throw PillError.invalidData
        }
        return try .init(coordinate: coordinate, celsius: celsius, emoji: emoji, updatedAt: now, source: .openMeteo)
    }
}
