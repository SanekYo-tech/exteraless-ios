import ExteralessCore
import Foundation
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import XCTest

/// Real public native formatters and native presence values. No account/network.
final class AppearancePresenceTests: XCTestCase {
    private func timestamp(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10, minute: Int = 15, second: Int = 47) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return Int32(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!.timeIntervalSince1970)
    }

    private func format(seconds: Bool, military: Bool = true, persian: Bool = false) -> PresentationDateTimeFormat {
        PresentationDateTimeFormat(timeFormat: military ? .military : .regular, dateFormat: .dayFirst,
            dateSeparator: ".", dateSuffix: "", requiresFullYear: true, decimalSeparator: ".", groupingSeparator: ",",
            showSeconds: seconds, identityCalendar: IdentityDatePolicy(usePersianCalendar: persian, latin: true), identityRevision: 7)
    }

    func testKnownAbsolutePresenceRetainsDateTimeAndSecondsAcrossAllDateBranches() {
        let strings = defaultPresentationStrings
        let now = timestamp(2026, 11, 15, hour: 20)
        for military in [false, true] {
            for seconds in [false, true, false] {
                let format = self.format(seconds: seconds, military: military)
                for expanded in [false, true] {
                    for date in [(2026, 11, 15), (2026, 11, 14), (2026, 11, 13), (2025, 11, 13)] {
                        let last = timestamp(date.0, date.1, date.2)
                        let presence = EnginePeer.Presence(TelegramUserPresence(status: .present(until: last), lastActivity: last))
                        let result = stringAndActivityForUserPresence(strings: strings, dateTimeFormat: format, presence: presence, relativeTo: now, expanded: expanded, relativeLastSeen: false)
                        XCTAssertFalse(result.1)
                        XCTAssertTrue(result.0.contains(stringForMessageTimestamp(timestamp: last, dateTimeFormat: format)), result.0)
                        XCTAssertEqual(result.0.contains(":47"), seconds, "seconds/reset: \(result.0)")
                        if date.2 == 13 {
                            XCTAssertTrue(result.0.contains("13.11.\(date.0)"), "older absolute date: \(result.0)")
                        }
                    }
                }
            }
        }
    }

    func testYesterdayActivityAndStoryUseSecondsInBothPublicPaths() {
        let now = timestamp(2026, 11, 15, hour: 20)
        let yesterday = timestamp(2026, 11, 14)
        for military in [false, true] {
            for seconds in [true, false] {
                let format = self.format(seconds: seconds, military: military)
                let time = stringForMessageTimestamp(timestamp: yesterday, dateTimeFormat: format)
                let activity = stringForRelativeActivityTimestamp(strings: defaultPresentationStrings, dateTimeFormat: format, relativeTimestamp: yesterday, relativeTo: now)
                let story = stringForStoryActivityTimestamp(strings: defaultPresentationStrings, dateTimeFormat: format, relativeTimestamp: yesterday, relativeTo: now, short: false)
                for value in [activity, story] {
                    XCTAssertTrue(value.contains(time), value)
                    XCTAssertEqual(value.contains(":47"), seconds, value)
                }
                let short = stringForStoryActivityTimestamp(strings: defaultPresentationStrings, dateTimeFormat: format, relativeTimestamp: yesterday, relativeTo: now, short: true)
                XCTAssertFalse(short.contains(":47"), "relative hours stay relative")
            }
        }
    }

    func testPrivacyBucketsAndPersianFastPathRemainNative() throws {
        let strings = defaultPresentationStrings
        let now = timestamp(2026, 11, 15, hour: 20)
        let privacyBuckets: [(UserPresenceStatus, String)] = [
            (.recently(isHidden: false), strings.LastSeen_Lately),
            (.lastWeek(isHidden: false), strings.LastSeen_WithinAWeek),
            (.lastMonth(isHidden: false), strings.LastSeen_WithinAMonth),
            (.none, strings.LastSeen_ALongTimeAgo)
        ]
        for relative in [false, true] {
            for seconds in [false, true] {
                for (status, expected) in privacyBuckets {
                    let result = stringAndActivityForUserPresence(strings: strings, dateTimeFormat: format(seconds: seconds), presence: EnginePeer.Presence(TelegramUserPresence(status: status, lastActivity: 0)), relativeTo: now, relativeLastSeen: relative)
                    XCTAssertEqual(result.0, expected)
                    XCTAssertFalse(result.1)
                }
            }
        }
        let last = timestamp(2026, 11, 13)
        let format = self.format(seconds: true, persian: true)
        let result = stringAndActivityForUserPresence(strings: strings, dateTimeFormat: format, presence: EnginePeer.Presence(TelegramUserPresence(status: .present(until: last), lastActivity: last)), relativeTo: now, expanded: true, relativeLastSeen: false)
        let persianDate = try XCTUnwrap(format.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(last)), style: .monthDay(includeYear: false)))
        XCTAssertTrue(result.0.contains(persianDate))
        XCTAssertTrue(result.0.contains(stringForMessageTimestamp(timestamp: last, dateTimeFormat: format)))
    }
}
