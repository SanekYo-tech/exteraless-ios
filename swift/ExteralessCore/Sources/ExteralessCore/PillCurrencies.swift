import Foundation

public enum PillCurrencies {
    public static let bases = ["USD", "EUR", "RUB", "GBP", "KZT", "TRY", "UAH", "PLN", "AED", "CNY", "JPY", "BYN", "ILS", "CZK", "INR", "TON", "BTC", "ETH", "SOL", "XAU"]
    public static let targets = ["AUTO", "AED", "BYN", "CNY", "CZK", "EUR", "GBP", "ILS", "INR", "JPY", "KZT", "PLN", "RUB", "TRY", "UAH", "USD"]

    /// The adapter supplies the active account's phone-country, never the device locale as a substitute.
    public static func resolve(_ selection: String, phoneCountry: String?) -> String {
        let value = selection.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value == "AUTO" else { return targets.contains(value) ? value : "USD" }
        guard let country = phoneCountry, country.count == 2 else { return "USD" }
        let currency = Locale(identifier: "en_" + country.uppercased()).currencyCode ?? "USD"
        return targets.contains(currency) ? currency : "USD"
    }

    public static func decimal(_ text: String) -> Decimal? {
        guard text.utf8.count <= 96, text.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value > 0,
              NSDecimalNumber(decimal: value).doubleValue.isFinite else { return nil }
        return value
    }
    public static func divide(_ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        guard !lhs.isNaN, !rhs.isNaN, lhs > 0, rhs > 0 else { return nil }
        var lhs = lhs; var rhs = rhs; var result = Decimal()
        let error = NSDecimalDivide(&result, &lhs, &rhs, .plain)
        guard (error == .noError || error == .lossOfPrecision), !result.isNaN, result > 0,
              NSDecimalNumber(decimal: result).doubleValue.isFinite else { return nil }
        return result
    }
    public static func text(_ value: Decimal, currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal; formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = currency == "JPY" ? 0 : 2
        formatter.maximumFractionDigits = formatter.minimumFractionDigits
        return (formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue) + " " + currency
    }
}

public struct PillRateTable: Equatable, Sendable {
    /// USD per one unit (the reciprocal of Coinbase's USD-base response).
    public let usdPerUnit: [String: Decimal]
    public let updatedAt: Date
    public init(usdPerUnit: [String: Decimal], updatedAt: Date) throws {
        guard !usdPerUnit.isEmpty, usdPerUnit["USD"] == Decimal(1),
              usdPerUnit.allSatisfy({ PillCurrencies.bases.contains($0.key) && !$0.value.isNaN && $0.value > 0 && NSDecimalNumber(decimal: $0.value).doubleValue.isFinite }) else { throw PillError.invalidData }
        _ = try PillFreshness.milliseconds(updatedAt)
        self.usdPerUnit = usdPerUnit; self.updatedAt = updatedAt
    }
    public func rate(base: String, target: String) -> Decimal? {
        guard let baseValue = usdPerUnit[base], let targetValue = usdPerUnit[target] else { return nil }
        return PillCurrencies.divide(baseValue, targetValue)
    }
    public static func parseCoinbase(_ data: Data, now: Date) throws -> PillRateTable {
        struct Response: Decodable {
            struct Payload: Decodable { let currency: String; let rates: [String: String] }
            let data: Payload
        }
        guard data.count <= 1_048_576, let response = try? JSONDecoder().decode(Response.self, from: data), response.data.currency == "USD" else { throw PillError.invalidData }
        var result: [String: Decimal] = ["USD": 1]
        for code in PillCurrencies.bases where code != "USD" && code != "XAU" {
            if let text = response.data.rates[code], let value = PillCurrencies.decimal(text), let inverted = PillCurrencies.divide(1, value) { result[code] = inverted }
        }
        guard result.count > 1 else { throw PillError.invalidData }
        return try .init(usdPerUnit: result, updatedAt: now)
    }
    public var serialized: String {
        usdPerUnit.keys.sorted().map { "\($0)=\(NSDecimalNumber(decimal: usdPerUnit[$0]!).stringValue)" }.joined(separator: ",")
    }
    public static func cached(_ raw: String, milliseconds: Int64) -> PillRateTable? {
        guard raw.utf8.count <= 16_384, let date = PillFreshness.date(milliseconds: milliseconds) else { return nil }
        var result: [String: Decimal] = [:]
        for part in raw.split(separator: ",") {
            let pieces = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pieces.count == 2, let value = PillCurrencies.decimal(String(pieces[1])), result[String(pieces[0])] == nil else { return nil }
            result[String(pieces[0])] = value
        }
        return try? .init(usdPerUnit: result, updatedAt: date)
    }
}

public struct PillGoldPrice: Equatable, Sendable {
    public let usdPerTroyOunce: Decimal
    public let updatedAt: Date
    public init(value: Decimal, updatedAt: Date) throws {
        guard !value.isNaN, value > 0, NSDecimalNumber(decimal: value).doubleValue.isFinite else { throw PillError.invalidData }
        _ = try PillFreshness.milliseconds(updatedAt)
        usdPerTroyOunce = value; self.updatedAt = updatedAt
    }
    public static func parse(_ data: Data, now: Date) throws -> PillGoldPrice {
        struct Response: Decodable { let price: Decimal }
        guard data.count <= 65_536, let response = try? JSONDecoder().decode(Response.self, from: data) else { throw PillError.invalidData }
        return try .init(value: response.price, updatedAt: now)
    }
}
