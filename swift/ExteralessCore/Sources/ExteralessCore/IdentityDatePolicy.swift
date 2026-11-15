import Foundation

public struct IdentityCalendarDate: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute; self.second = second
    }
}

/// Semantic date conversion using Foundation's Persian calendar. In particular
/// this does not copy PersianDate.java's 33-year approximation / post-2029 fix,
/// or its repeated single-letter pattern substitution (which corrupts words).
public struct IdentityDatePolicy: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case monthDay(includeYear: Bool)
        case monthYear
        case numeric(dayFirst: Bool, separator: String, suffix: String, fullYear: Bool)
        case numericMonthDay(dayFirst: Bool, separator: String, suffix: String)
        case year
    }

    public let usePersianCalendar: Bool
    public let latin: Bool

    public init(usePersianCalendar: Bool = false, latin: Bool = false) {
        self.usePersianCalendar = usePersianCalendar
        self.latin = latin
    }

    private static let months = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"]
    private static let latinMonths = ["Farvardin", "Ordibehesht", "Khordad", "Tir", "Mordad", "Shahrivar", "Mehr", "Aban", "Azar", "Dey", "Bahman", "Esfand"]

    private static func isCivilDate(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite && timestamp >= -62_135_596_800 && timestamp < 253_402_300_800
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .persian)
        calendar.locale = Locale(identifier: "fa_IR")
        calendar.timeZone = timeZone
        return calendar
    }

    /// Supported civil-date range; invalid/nonfinite inputs fall back to the
    /// caller's native formatter. Telegram's entire Int32 timestamp range fits.
    public static func components(at date: Date, timeZone: TimeZone) -> IdentityCalendarDate? {
        guard isCivilDate(date) else { return nil }
        let components = calendar(timeZone: timeZone).dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        guard components.era == 1, let year = components.year, (1...9378).contains(year),
              let month = components.month, (1...12).contains(month), let day = components.day, (1...31).contains(day),
              let hour = components.hour, let minute = components.minute, let second = components.second else { return nil }
        return IdentityCalendarDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// Rejects normalization (Esfand 30 in a non-leap year, month 13 and skipped
    /// DST wall times). The time zone belongs to the requested date, not "now".
    public static func date(from value: IdentityCalendarDate, timeZone: TimeZone) -> Date? {
        guard (1...9378).contains(value.year), (1...12).contains(value.month), (1...31).contains(value.day),
              (0...23).contains(value.hour), (0...59).contains(value.minute), (0...59).contains(value.second) else { return nil }
        let calendar = calendar(timeZone: timeZone)
        var components = DateComponents()
        components.era = 1; components.year = value.year; components.month = value.month; components.day = value.day
        components.hour = value.hour; components.minute = value.minute; components.second = value.second
        guard let date = calendar.date(from: components), Self.components(at: date, timeZone: timeZone) == value else { return nil }
        return date
    }

    public func persianText(for date: Date, style: Style, timeZone: TimeZone = .current) -> String? {
        guard usePersianCalendar, let value = Self.components(at: date, timeZone: timeZone) else { return nil }
        let month = (latin ? Self.latinMonths : Self.months)[value.month - 1]
        let text: String
        switch style {
        case let .monthDay(includeYear):
            text = "\(value.day) \(month)" + (includeYear ? " \(value.year)" : "")
        case .monthYear: text = "\(month) \(value.year)"
        case let .numeric(dayFirst, separator, suffix, fullYear):
            let parts = dayFirst ? [value.day, value.month] : [value.month, value.day]
            let year = fullYear ? String(value.year) : Self.padded(value.year % 100)
            text = Self.padded(parts[0]) + separator + Self.padded(parts[1]) + separator + year + suffix
        case let .numericMonthDay(dayFirst, separator, suffix):
            let parts = dayFirst ? [value.day, value.month] : [value.month, value.day]
            text = Self.padded(parts[0]) + separator + Self.padded(parts[1]) + suffix
        case .year: text = String(value.year)
        }
        return digits(in: text)
    }

    /// Only call on date/time text, never a message, account ID or arbitrary
    /// localized sentence. Both numeral alphabets are mapped in one pass.
    public func digits(in text: String) -> String {
        guard usePersianCalendar else { return text }
        let zero: UInt32 = latin ? 0x30 : 0x6f0
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let digit: UInt32?
            switch scalar.value {
            case 0x30...0x39: digit = scalar.value - 0x30
            case 0x660...0x669: digit = scalar.value - 0x660
            case 0x6f0...0x6f9: digit = scalar.value - 0x6f0
            default: digit = nil
            }
            output.append(digit.flatMap { UnicodeScalar(zero + $0) } ?? scalar)
        }
        return String(output)
    }

    public func sameYear(_ lhs: Date, _ rhs: Date, timeZone: TimeZone = .current) -> Bool {
        guard Self.isCivilDate(lhs), Self.isCivilDate(rhs) else { return false }
        var calendar = Calendar(identifier: usePersianCalendar ? .persian : .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(lhs, equalTo: rhs, toGranularity: .year)
    }

    /// A Gregorian-grouped media month is still an interval, not a Persian
    /// month. Preserve its real endpoints when presenting it in another calendar.
    public func persianRange(from start: Date, through end: Date, timeZone: TimeZone = .current) -> String? {
        guard start <= end, let first = persianText(for: start, style: .monthDay(includeYear: true), timeZone: timeZone),
              let last = persianText(for: end, style: .monthDay(includeYear: true), timeZone: timeZone) else { return nil }
        return first == last ? first : first + " – " + last
    }

    public static func gregorianDate(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A civil date, not a timestamp: noon avoids a skipped midnight in zones
        // that advance the clock at the start of a day.
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return date
    }

    /// Calendar-day arithmetic, rather than 86400-second subtraction, preserves
    /// Today/Yesterday across New Year and daylight-saving changes.
    public static func dayDistance(from lhs: Date, to rhs: Date, timeZone: TimeZone) -> Int? {
        guard isCivilDate(lhs), isCivilDate(rhs) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: lhs), to: calendar.startOfDay(for: rhs)).day
    }

    private static func padded(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}
