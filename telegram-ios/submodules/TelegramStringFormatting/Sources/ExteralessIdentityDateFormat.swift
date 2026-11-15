import ExteralessCore
import Foundation
import TelegramCore
import TelegramPresentationData
import TextFormat

public func exteralessIdentityForwardDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, now: Date = Date()) -> String? {
    guard ExteralessIdentityPresentation.shared.policy.dateOfForwardedMsg, timestamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: dateTimeFormat)
    if IdentityDatePolicy.dayDistance(from: date, to: now, timeZone: .current) == 0 { return time }
    let calendar = dateTimeFormat.identityCalendar
    let day = calendar.persianText(for: date, style: .monthDay(includeYear: !calendar.sameYear(date, now)))
        ?? stringForDate(date: date, timeZone: .current, strings: strings)
    return strings.Time_AtPreciseDate(day, time).string
}

func exteralessIdentityListDate(timestamp: Int32, now: Int32, strings: PresentationStrings, format: PresentationDateTimeFormat, precise: Bool = false) -> String? {
    guard format.identityCalendar.usePersianCalendar else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let current = Date(timeIntervalSince1970: Double(now))
    guard let days = IdentityDatePolicy.dayDistance(from: date, to: current, timeZone: .current) else { return nil }
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: format)
    if days == 0 { return time }
    if !precise && (1...6).contains(days) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return shortStringForDayOfWeek(strings: strings, day: Int32(calendar.component(.weekday, from: date) - 1))
    }
    let text = format.identityCalendar.persianText(for: date, style: .monthDay(includeYear: !format.identityCalendar.sameYear(date, current)))
    if precise, let text { return strings.Time_AtPreciseDate(text, time).string }
    return text
}

func exteralessIdentityLastSeen(timestamp: Int32, now: Int32, strings: PresentationStrings, format: PresentationDateTimeFormat) -> String? {
    guard format.identityCalendar.usePersianCalendar, timestamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let current = Date(timeIntervalSince1970: Double(now))
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: format)
    switch IdentityDatePolicy.dayDistance(from: date, to: current, timeZone: .current) {
    case 0?: return strings.LastSeen_TodayAt(time).string
    case 1?: return strings.LastSeen_YesterdayAt(time).string
    default:
        guard let dateText = format.identityCalendar.persianText(for: date, style: .monthDay(includeYear: !format.identityCalendar.sameYear(date, current))) else { return nil }
        return strings.LastSeen_AtDate(strings.Time_AtPreciseDate(dateText, time).string).string
    }
}
