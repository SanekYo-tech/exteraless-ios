import Foundation

public enum MapFeatures {
    public static let keys: Set<String> = ["maps.mapPreviewProvider", "maps.useOSMDroidMap", "maps.mapDriftingFixForGoogleMaps", "maps.yandexAPIKey"]
    public static let definitions: [ClientSettingDefinition] = [
        .init(key: "maps.mapPreviewProvider", title: "Map previews", section: "Maps", defaultValue: .integer(0), options: [
            .init(value: .integer(0), title: "Telegram (Apple Maps on iOS)"),
            .init(value: .integer(1), title: "Yandex"),
            .init(value: .integer(2), title: "Disabled")
        ], explanation: "Cloud-message and article previews. Secret chats retain their native preview policy. Unavailable providers show a labelled Apple Maps fallback.", androidSymbols: ["NekoConfig.mapPreviewProvider"]),
        .init(key: "maps.useOSMDroidMap", title: "OpenStreetMap in location picker", section: "Maps", defaultValue: .bool(false),
              explanation: "Uses OpenStreetMap standard tiles in the native map view. Satellite and hybrid use Apple Maps and are labelled accordingly. Downloads only visible tiles; no offline region download.", androidSymbols: ["NekoConfig.useOSMDroidMap"]),
        .init(key: "maps.mapDriftingFixForGoogleMaps", title: "Correct Google Maps coordinates", section: "Maps", defaultValue: .bool(true),
              explanation: "Original WGS84 → GCJ-02 correction for Google Maps navigation in the original China bounds. Apple Maps, OSM, Yandex and sent message coordinates stay WGS84. Disabled while OpenStreetMap is selected, as in the original.", androidSymbols: ["NekoConfig.mapDriftingFixForGoogleMaps"]),
        .init(key: "maps.yandexAPIKey", title: "Yandex Static Maps API key", section: "Maps", defaultValue: .string(""), isSecret: true,
              explanation: "Optional provider credential, stored in Keychain. Without a key the original public endpoint is attempted; HTTP failure is shown as a fallback, never as a successful Yandex map.")
    ]
}

public enum MapPreviewScope: String, Hashable, Sendable {
    case cloudMessage, instantPage, secretChat, other
}

public struct MapPolicy: Equatable, Sendable {
    public enum Preview: Int, Hashable, Sendable { case native = 0, yandex = 1, disabled = 2 }
    public let preview: Preview
    public let useOpenStreetMap: Bool
    public let correctGoogleCoordinates: Bool
    public init(preview: Preview = .native, useOpenStreetMap: Bool = false, correctGoogleCoordinates: Bool = true) {
        self.preview = preview; self.useOpenStreetMap = useOpenStreetMap; self.correctGoogleCoordinates = correctGoogleCoordinates
    }
    public static func current(settings: ClientSettings = .shared) -> Self {
        let values = settings.readSnapshot().values
        let preview: Preview
        if case let .integer(value)? = values["maps.mapPreviewProvider"], let number = Int(exactly: value), let valid = Preview(rawValue: number) { preview = valid }
        else { preview = .native }
        return Self(preview: preview, useOpenStreetMap: values["maps.useOSMDroidMap"] == .bool(true), correctGoogleCoordinates: values["maps.mapDriftingFixForGoogleMaps"] != .bool(false))
    }
    public func preview(for scope: MapPreviewScope) -> Preview {
        return scope == .cloudMessage || scope == .instantPage ? preview : .native
    }
    public func googleCoordinate(_ coordinate: MapCoordinate) -> MapCoordinate {
        guard correctGoogleCoordinates, !useOpenStreetMap else { return coordinate }
        return MapCoordinatePolicy.googleDisplay(coordinate)
    }
}

public struct MapCoordinate: Hashable, Sendable {
    public enum Datum: Hashable, Sendable { case wgs84, gcj02 }
    public let latitude: Double
    public let longitude: Double
    public let datum: Datum
    public init?(latitude: Double, longitude: Double, datum: Datum = .wgs84) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude; self.longitude = longitude; self.datum = datum
    }
}

public enum MapCoordinatePolicy {
    /// Exact GeodeticTransform.java constants and rectangular source bounds. The
    /// datum tag replaces Android's collision-prone recent-coordinate hash cache.
    public static func googleDisplay(_ coordinate: MapCoordinate) -> MapCoordinate {
        guard coordinate.datum == .wgs84,
              (72.004...137.8347).contains(coordinate.longitude), (0.8293...55.8271).contains(coordinate.latitude) else { return coordinate }
        let x = coordinate.longitude - 105, y = coordinate.latitude - 35, pi = Double.pi
        var latitude = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        latitude += (20 * sin(6 * x * pi) + 20 * sin(2 * x * pi)) * 2 / 3
        latitude += (20 * sin(y * pi) + 40 * sin(y / 3 * pi)) * 2 / 3
        latitude += (160 * sin(y / 12 * pi) + 320 * sin(y * pi / 30)) * 2 / 3
        var longitude = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        longitude += (20 * sin(6 * x * pi) + 20 * sin(2 * x * pi)) * 2 / 3
        longitude += (20 * sin(x * pi) + 40 * sin(x / 3 * pi)) * 2 / 3
        longitude += (150 * sin(x / 12 * pi) + 300 * sin(x / 30 * pi)) * 2 / 3
        let radians = coordinate.latitude / 180 * pi
        let eccentricity = 0.00669342162296594323, axis = 6378245.0
        let magic = 1 - eccentricity * sin(radians) * sin(radians), root = sqrt(magic)
        latitude = latitude * 180 / ((axis * (1 - eccentricity)) / (magic * root) * pi)
        longitude = longitude * 180 / (axis / root * cos(radians) * pi)
        return MapCoordinate(latitude: coordinate.latitude + latitude, longitude: coordinate.longitude + longitude, datum: .gcj02) ?? coordinate
    }
}

public enum MapProviderURL {
    public static func yandexPreview(coordinate: MapCoordinate, width: Int, height: Int, zoom: Int = 15, language: String = "en", apiKey: String = "") -> URL? {
        guard coordinate.datum == .wgs84, (1...650).contains(width), (1...450).contains(height), (1...17).contains(zoom), apiKey.utf8.count <= 2048 else { return nil }
        var components = URLComponents(string: "https://static-maps.yandex.ru/1.x/")!
        let position = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude, coordinate.latitude)
        let language = language.hasPrefix("ru") ? "ru_RU" : language.hasPrefix("tr") ? "tr_TR" : "en_US"
        components.queryItems = [
            .init(name: "ll", value: position), .init(name: "z", value: String(zoom)),
            .init(name: "size", value: "\(width),\(height)"), .init(name: "l", value: "map"),
            .init(name: "scale", value: "1"), .init(name: "lang", value: language)
        ]
        if !apiKey.isEmpty { components.queryItems?.append(.init(name: "apikey", value: apiKey)) }
        return components.url
    }

    public static func openStreetMapTile(x: Int, y: Int, zoom: Int) -> URL? {
        guard (0...19).contains(zoom) else { return nil }
        let count = 1 << zoom
        guard (0..<count).contains(x), (0..<count).contains(y) else { return nil }
        return URL(string: "https://tile.openstreetmap.org/\(zoom)/\(x)/\(y).png")
    }

    public static func openStreetMap(coordinate: MapCoordinate) -> URL? {
        guard coordinate.datum == .wgs84 else { return nil }
        var components = URLComponents(string: "https://www.openstreetmap.org/")!
        components.queryItems = [.init(name: "mlat", value: String(coordinate.latitude)), .init(name: "mlon", value: String(coordinate.longitude))]
        components.fragment = "map=16/\(coordinate.latitude)/\(coordinate.longitude)"
        return components.url
    }
}
