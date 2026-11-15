import Foundation

/// Native-authored, closed JSON schemas. No executable validation callbacks.
public indirect enum ClientSettingShape: Equatable, Sendable {
    case any, null, bool, integer, number, string
    case array(ClientSettingShape, maximumCount: Int)
    case object([String: ClientSettingShape], required: Set<String>)

    func validateDefinition(key: String, depth: Int = 0) throws {
        guard depth <= 60 else { throw ClientSettingsError.invalidDefinition(key: key) }
        switch self {
        case let .array(element, maximumCount):
            guard maximumCount >= 0 else { throw ClientSettingsError.invalidDefinition(key: key) }
            try element.validateDefinition(key: key, depth: depth + 1)
        case let .object(fields, required):
            guard required.isSubset(of: fields.keys) else { throw ClientSettingsError.invalidDefinition(key: key) }
            for shape in fields.values { try shape.validateDefinition(key: key, depth: depth + 1) }
        default:
            break
        }
    }

    func validate(_ value: ClientSettingValue, key: String, depth: Int = 0) throws {
        guard depth <= 60 else { throw ClientSettingsError.invalidValue(key: key, reason: .shape) }
        switch (self, value) {
        case (.any, _):
            try value.validateJSON(depth: depth)
        case (.null, .null), (.bool, .bool), (.integer, .integer), (.number, .integer), (.string, .string):
            break
        case let (.integer, .number(number)):
            guard Int64(exactly: number) != nil else { throw ClientSettingsError.invalidValue(key: key, reason: .shape) }
        case let (.number, .number(number)):
            guard number.isFinite else { throw ClientSettingsError.nonFiniteNumber }
        case let (.array(element, maximumCount), .array(values)):
            guard maximumCount >= 0, values.count <= maximumCount else { throw ClientSettingsError.invalidValue(key: key, reason: .shape) }
            for value in values { try element.validate(value, key: key, depth: depth + 1) }
        case let (.object(fields, required), .object(values)):
            guard Set(values.keys).isSubset(of: fields.keys), required.isSubset(of: values.keys) else {
                throw ClientSettingsError.invalidValue(key: key, reason: .shape)
            }
            for (field, value) in values {
                guard let shape = fields[field] else { throw ClientSettingsError.invalidValue(key: key, reason: .shape) }
                try shape.validate(value, key: key, depth: depth + 1)
            }
        default:
            throw ClientSettingsError.invalidValue(key: key, reason: .shape)
        }
    }
}

public struct ClientSettingOption: Equatable, Sendable {
    public let value: ClientSettingValue
    public let title: String

    public init(value: ClientSettingValue, title: String) {
        self.value = value
        self.title = title
    }
}

/// Registration is a schema declaration, not evidence that a feature is applied.
/// Domains must register only settings with a connected native consumer.
public struct ClientSettingDefinition: Equatable, Sendable {
    public let key: String
    public let title: String
    public let section: String
    public let defaultValue: ClientSettingValue
    public let options: [ClientSettingOption]
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let isSecret: Bool
    public let explanation: String?
    public let androidSymbols: [String]
    public let valueShape: ClientSettingShape?

    public init(key: String, title: String, section: String,
                defaultValue: ClientSettingValue,
                options: [ClientSettingOption] = [],
                minimum: Double? = nil, maximum: Double? = nil,
                step: Double? = nil, isSecret: Bool = false,
                explanation: String? = nil, androidSymbols: [String] = [],
                valueShape: ClientSettingShape? = nil) {
        self.key = key
        self.title = title
        self.section = section
        self.defaultValue = defaultValue
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.isSecret = isSecret
        self.explanation = explanation
        self.androidSymbols = androidSymbols
        self.valueShape = valueShape
    }

    /// Validates type, enum membership, bounds and the step anchored at minimum
    /// (or zero). No truncation, clamping, string-to-number or bool coercion.
    public func validatedValue(_ value: ClientSettingValue) throws -> ClientSettingValue {
        try self.valueShape?.validate(value, key: self.key)
        try value.validateJSON()
        var value = try self.typedValue(value)
        if !self.options.isEmpty {
            let allowed = try self.options.map { try self.typedValue($0.value) }
            guard let canonical = allowed.first(where: { $0.isSameJSONValue(as: value) }) else {
                throw ClientSettingsError.invalidValue(key: self.key, reason: .option)
            }
            value = canonical
        }
        try self.validateRange(value)
        return value
    }

    public func validate(_ value: ClientSettingValue) throws {
        _ = try self.validatedValue(value)
    }

    func validateDefinition() throws {
        guard Self.isValidKey(self.key) else { throw ClientSettingsError.invalidKey }
        try self.valueShape?.validateDefinition(key: self.key)
        guard !self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientSettingsError.invalidDefinition(key: self.key)
        }
        for bound in [self.minimum, self.maximum, self.step].compactMap({ $0 }) {
            guard bound.isFinite else { throw ClientSettingsError.invalidDefinition(key: self.key) }
        }
        if let minimum = self.minimum, let maximum = self.maximum, minimum > maximum {
            throw ClientSettingsError.invalidDefinition(key: self.key)
        }
        if let step = self.step, step <= 0.0 {
            throw ClientSettingsError.invalidDefinition(key: self.key)
        }
        if self.minimum != nil || self.maximum != nil || self.step != nil {
            switch self.defaultValue {
            case .integer:
                for bound in [self.minimum, self.maximum, self.step].compactMap({ $0 }) {
                    guard Int64(exactly: bound) != nil else {
                        throw ClientSettingsError.invalidDefinition(key: self.key)
                    }
                }
            case .number:
                break
            default:
                throw ClientSettingsError.invalidDefinition(key: self.key)
            }
        }
        if self.isSecret {
            // Credentials are supplied at runtime, never embedded in a schema or
            // its enum options, which are safe to inspect and localize.
            let emptyDefault: Bool
            switch self.defaultValue {
            case let .string(value): emptyDefault = value.isEmpty
            case let .array(value): emptyDefault = value.isEmpty
            case let .object(value): emptyDefault = value.isEmpty
            default: emptyDefault = true
            }
            guard emptyDefault, self.options.isEmpty else {
                throw ClientSettingsError.invalidDefinition(key: self.key)
            }
        }
        var optionValues: [ClientSettingValue] = []
        for option in self.options {
            try self.valueShape?.validate(option.value, key: self.key)
            try option.value.validateJSON()
            let value = try self.typedValue(option.value)
            guard !option.title.isEmpty, !optionValues.contains(where: { $0.isSameJSONValue(as: value) }) else {
                throw ClientSettingsError.invalidDefinition(key: self.key)
            }
            try self.validateRange(value)
            optionValues.append(value)
        }
        _ = try self.validatedValue(self.defaultValue)
    }

    static func isValidKey(_ key: String) -> Bool {
        return !key.isEmpty && key.utf8.count <= 256 && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 45 || $0 == 95
        }
    }

    func canReplace(_ previous: ClientSettingDefinition) -> Bool {
        if previous.isSecret && !self.isSecret { return false }
        switch (previous.defaultValue, self.defaultValue) {
        case (.null, .null), (.bool, .bool), (.integer, .integer), (.number, .number), (.string, .string), (.array, .array), (.object, .object):
            return true
        default:
            return false
        }
    }

    private func typedValue(_ value: ClientSettingValue) throws -> ClientSettingValue {
        switch (self.defaultValue, value) {
        case (.null, _), (.bool, .bool), (.string, .string), (.array, .array), (.object, .object), (.integer, .integer), (.number, .number):
            return value
        case let (.number, .integer(integer)):
            // Preserve Int64 precision: callers must not accidentally round an ID.
            guard let number = Double(exactly: integer) else {
                throw ClientSettingsError.invalidValue(key: self.key, reason: .type)
            }
            return .number(number)
        case let (.integer, .number(number)):
            guard let integer = Int64(exactly: number) else {
                throw ClientSettingsError.invalidValue(key: self.key, reason: .type)
            }
            return .integer(integer)
        default:
            throw ClientSettingsError.invalidValue(key: self.key, reason: .type)
        }
    }

    private func validateRange(_ value: ClientSettingValue) throws {
        if case let .integer(integer) = value {
            if let minimum = self.minimum {
                guard let bound = Int64(exactly: minimum), integer >= bound else {
                    throw ClientSettingsError.invalidValue(key: self.key, reason: .range)
                }
            }
            if let maximum = self.maximum {
                guard let bound = Int64(exactly: maximum), integer <= bound else {
                    throw ClientSettingsError.invalidValue(key: self.key, reason: .range)
                }
            }
        }
        let number: Double
        switch value {
        case let .integer(value): number = Double(value)
        case let .number(value): number = value
        default: return
        }
        if let minimum = self.minimum, number < minimum {
            throw ClientSettingsError.invalidValue(key: self.key, reason: .range)
        }
        if let maximum = self.maximum, number > maximum {
            throw ClientSettingsError.invalidValue(key: self.key, reason: .range)
        }
        guard let step = self.step else { return }
        if case let .integer(integer) = value,
           let stride = Int64(exactly: step), stride > 0,
           let origin = Int64(exactly: self.minimum ?? 0.0) {
            let lhs = integer % stride
            let rhs = origin % stride
            guard (lhs < 0 ? lhs + stride : lhs) == (rhs < 0 ? rhs + stride : rhs) else {
                throw ClientSettingsError.invalidValue(key: self.key, reason: .step)
            }
        } else {
            let units = (number - (self.minimum ?? 0.0)) / step
            let tolerance = min(0.000001, max(0.000000001, abs(units.ulp) * 4.0))
            guard units.isFinite, abs(units - units.rounded()) <= tolerance else {
                throw ClientSettingsError.invalidValue(key: self.key, reason: .step)
            }
        }
    }
}
