import Foundation

/// Values cross the host boundary as JSON scalars, never as Python source.
enum PluginSettingValue: Decodable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func json() throws -> String {
        let data: Data
        let encoder = JSONEncoder()
        switch self {
        case let .bool(value):
            data = try encoder.encode(value)
        case let .number(value):
            data = try encoder.encode(value)
        case let .string(value):
            data = try encoder.encode(value)
        case .null:
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    var string: String {
        if case let .string(value) = self {
            return value
        }
        return ""
    }
}

struct PluginSliderRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double
    let step: Double

    init(minimum: Double, maximum: Double, step: Double) throws {
        let span = maximum - minimum
        guard minimum.isFinite, maximum.isFinite, step.isFinite, span.isFinite,
              maximum > minimum, step > 0.0, ceil(span / step) <= 2147483647.0 else {
            throw PluginSettingsSchemaError(message: pluginText("Settings.InvalidSlider", "Invalid slider range or step"))
        }
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    /// Matches ui.settings.Slider.normalize, including a non-divisible upper bound.
    func normalize(_ value: Double) -> Double {
        let clamped = min(self.maximum, max(self.minimum, value.isFinite ? value : self.minimum))
        let quantized = self.minimum + floor((clamped - self.minimum) / self.step + 0.5) * self.step
        return min(self.maximum, max(self.minimum, quantized))
    }

    func fraction(_ value: Double) -> Float {
        return Float((self.normalize(value) - self.minimum) / (self.maximum - self.minimum))
    }

    func value(at fraction: Float) -> Double {
        return self.normalize(self.minimum + Double(fraction) * (self.maximum - self.minimum))
    }

    func label(_ value: Double) -> String {
        // NumberFormatter keeps tiny steps readable and avoids binary rounding tails.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 15
        formatter.usesSignificantDigits = true
        return formatter.string(from: NSNumber(value: self.normalize(value))) ?? String(value)
    }
}

struct PluginSetting: Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case header
        case divider
        case `switch`
        case selector
        case input
        case edittext
        case text
        case slider
    }

    var identifier = ""
    let type: String
    let rowId: String?
    let key: String?
    let text: String?
    let subtext: String?
    let hint: String?
    let value: PluginSettingValue?
    let defaultValue: PluginSettingValue?
    let items: [String]?
    let minimum: Double?
    let maximum: Double?
    let step: Double?
    let accent: Bool?
    let red: Bool?
    let multiline: Bool?
    let maxLength: Int?
    let callbackId: String?
    let longCallbackId: String?
    var subPage: [PluginSetting]?

    private enum CodingKeys: String, CodingKey {
        case type, key, text, subtext, hint, value, items, step, accent, red, multiline
        case rowId = "row_id"
        case defaultValue = "default"
        case minimum = "min"
        case maximum = "max"
        case maxLength = "max_length"
        case callbackId = "callback_id"
        case longCallbackId = "long_callback_id"
        case subPage = "sub_page"
    }

    var kind: Kind? {
        return Kind(rawValue: self.type == "edit_text" ? "edittext" : self.type)
    }

    var currentValue: PluginSettingValue? {
        return self.value ?? self.defaultValue
    }

    var title: String {
        return self.text ?? self.hint ?? self.key ?? self.type
    }

    var sliderRange: PluginSliderRange? {
        guard self.kind == .slider else {
            return nil
        }
        return try? PluginSliderRange(minimum: self.minimum ?? 0.0, maximum: self.maximum ?? 100.0, step: self.step ?? 1.0)
    }
}

struct PluginSettingsSchemaError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return self.message
    }
}

enum PluginSettingsDocument {
    /// Explicit UI bounds keep an erroneous settings response from exhausting layout.
    static func decode(_ json: String) throws -> [PluginSetting] {
        guard json.utf8.count <= 1024 * 1024 else {
            throw PluginSettingsSchemaError(message: pluginText("Settings.ResponseTooLarge", "Settings response exceeds 1 MiB"))
        }
        let rows = try JSONDecoder().decode([PluginSetting].self, from: Data(json.utf8))
        var count = 0
        return try self.validate(rows, depth: 0, count: &count)
    }

    static func page(in document: [PluginSetting], path: [String]) -> [PluginSetting]? {
        var page = document
        for identifier in path {
            guard let next = page.first(where: { $0.identifier == identifier })?.subPage else {
                return nil
            }
            page = next
        }
        return page
    }

    private static func validate(_ rows: [PluginSetting], depth: Int, count: inout Int) throws -> [PluginSetting] {
        guard depth <= 16 else {
            throw PluginSettingsSchemaError(message: pluginText("Settings.TooManyLevels", "Settings subpages exceed 16 levels"))
        }
        var identifiers = Set<String>()
        var occurrences: [String: Int] = [:]
        var result: [PluginSetting] = []
        for (index, source) in rows.enumerated() {
            count += 1
            guard count <= 1000 else {
                throw PluginSettingsSchemaError(message: pluginText("Settings.TooManyRows", "Settings response exceeds 1,000 rows"))
            }
            var row = source
            let identity = row.rowId ?? [row.type, row.key ?? row.callbackId ?? row.text ?? String(index)].joined(separator: ":")
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            row.identifier = row.rowId ?? "\(identity):\(occurrence)"
            guard identifiers.insert(row.identifier).inserted else {
                throw PluginSettingsSchemaError(message: pluginText("Settings.DuplicateRow", "Duplicate settings row_id") + ": \(row.identifier)")
            }
            if let kind = row.kind {
                switch kind {
                case .switch, .selector, .input, .edittext, .slider:
                    guard let key = row.key, !key.isEmpty else {
                        throw PluginSettingsSchemaError(message: pluginText("Settings.MissingKey", "Missing setting key") + ": #\(index + 1) (\(row.type))")
                    }
                default:
                    break
                }
                var valid = true
                switch kind {
                case .switch:
                    if case .bool = row.currentValue {} else { valid = false }
                case .selector:
                    if case let .number(value) = row.currentValue {
                        valid = row.items != nil && value.isFinite && value.rounded() == value
                        if let items = row.items, items.count > 1000 {
                            throw PluginSettingsSchemaError(message: pluginText("Settings.TooManyOptions", "Selector exceeds 1,000 options") + ": \(row.key ?? row.identifier)")
                        }
                    } else {
                        valid = false
                    }
                case .input, .edittext:
                    switch row.currentValue {
                    case .string, .null, .none:
                        break
                    default:
                        valid = false
                    }
                    if let length = row.maxLength, length < 0 {
                        valid = false
                    }
                case .slider:
                    if case let .number(value) = row.currentValue {
                        valid = value.isFinite && row.sliderRange != nil
                    } else {
                        valid = false
                    }
                case .header, .divider, .text:
                    break
                }
                guard valid else {
                    throw PluginSettingsSchemaError(message: pluginText("Settings.InvalidValue", "Invalid value or options for setting") + " \(row.key ?? row.identifier) (\(row.type))")
                }
            }
            if let subPage = row.subPage {
                row.subPage = try self.validate(subPage, depth: depth + 1, count: &count)
            }
            result.append(row)
        }
        return result
    }
}
