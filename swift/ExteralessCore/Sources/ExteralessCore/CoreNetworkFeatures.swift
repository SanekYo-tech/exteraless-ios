import Foundation

public enum NewNetworkFeatures {
    public static let keys: Set<String> = ["network.dnsType", "network.customDoH", "network.useIPv6"]

    public static let definitions: [ClientSettingDefinition] = [
        .init(key: "network.dnsType", title: "App DNS resolver", section: "Network", defaultValue: .integer(0), options: [
            .init(value: .integer(0), title: "Telegram (native iOS resolver)"),
            .init(value: .integer(1), title: "NagramX DNS over HTTPS"),
            .init(value: .integer(2), title: "System resolver"),
            .init(value: .integer(3), title: "Custom DNS over HTTPS")
        ], explanation: "Applies to this app's MTProto connections and backup discovery. Does not configure device-wide DNS, Safari, WebKit or other apps. DoH failures may fall back to the native resolver.", androidSymbols: ["NekoConfig.dnsType"]),
        .init(key: "network.customDoH", title: "Custom DoH endpoints", section: "Network", defaultValue: .string(""), isSecret: true,
              explanation: "Comma-separated HTTPS URLs. Ordinary URLs use DNS-wire POST; an RFC 8484 {?dns} template uses GET. Known Google /resolve and Mozilla /dns-query URLs use DNS-JSON GET. Empty uses the original NagramX providers. Stored in Keychain because a URL can contain a token. TLS uses normal certificate validation.", androidSymbols: ["NekoConfig.customDoH"]),
        .init(key: "network.useIPv6", title: "Prefer IPv6", section: "Network", defaultValue: .bool(false),
              explanation: "Prefer IPv6 when the current path supports it; retain IPv4 fallback. IPv6-only paths remain usable with this switch off.", androidSymbols: ["NekoConfig.useIPv6"])
    ]

    /// Used by the native editor as well as by the runtime. Invalid input is never
    /// silently reported as an applied custom resolver.
    public static func validate(_ value: ClientSettingValue, for key: String) throws {
        if key == "network.customDoH", case let .string(text) = value {
            _ = try NetworkResolverConfiguration.customEndpoints(text)
        }
    }
}
