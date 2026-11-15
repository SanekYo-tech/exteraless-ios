import Foundation

/// The four layout definitions remain owned by ChatFeatures. Register both domains.
public enum PillFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        field("gramTargetCurrency", "GRAM target currency", .string("AUTO")),
        field("btcTargetCurrency", "BTC target currency", .string("AUTO")),
        field("usdTargetCurrency", "USD target currency", .string("AUTO")),
        field("goldTargetCurrency", "Gold target currency", .string("AUTO")),
        field("ethTargetCurrency", "ETH target currency", .string("AUTO")),
        field("eurTargetCurrency", "EUR target currency", .string("AUTO")),
        field("rateInstancesRaw", "Rate pairs", .string("")),
        field("rateInstancesMigrated", "Rate layout migrated", .bool(false)),
        field("goldPriceCache", "Gold cache (USD / troy oz)", .string("")),
        field("goldPriceCacheTime", "Gold cache time (Unix ms)", .integer(0)),
        field("ratesCache", "Exchange rates cache (USD / unit)", .string("")),
        field("ratesCacheTime", "Exchange rates cache time (Unix ms)", .integer(0)),
        field("weatherUseCurrentLocation", "Use current weather location", .bool(true)),
        field("weatherLatitude", "Weather latitude", .string("")),
        field("weatherLongitude", "Weather longitude", .string("")),
        field("weatherAddress", "Weather location name", .string("")),
        ClientSettingDefinition(key: "pills.weatherProvider", title: "Weather source", section: "Chats · Status pills", defaultValue: .string("telegram"), options: [
            ClientSettingOption(value: .string("telegram"), title: "Telegram weather bot"),
            ClientSettingOption(value: .string("openMeteo"), title: "Open-Meteo")
        ], explanation: "Telegram is the active Android source. Open-Meteo uses the endpoint preserved in its earlier implementation. Only the selected, visible weather pill requests data.", androidSymbols: ["Weather.fetch"]),
        ClientSettingDefinition(key: "pills.weatherUnits", title: "Weather temperature units", section: "Chats · Status pills", defaultValue: .string("AUTO"), options: [
            ClientSettingOption(value: .string("AUTO"), title: "Automatic"),
            ClientSettingOption(value: .string("C"), title: "Celsius"),
            ClientSettingOption(value: .string("F"), title: "Fahrenheit")
        ], androidSymbols: ["Weather.State.getTemperature", "Weather.isDefaultCelsius"])
    ]

    private static func field(_ name: String, _ title: String, _ value: ClientSettingValue) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "chats." + name, title: title, section: "Chats · Status pill data", defaultValue: value,
            explanation: "Managed atomically by Status Pills. Cache timestamps are observation times, not a guarantee of freshness.", androidSymbols: ["PillStackConfig." + name])
    }
}
