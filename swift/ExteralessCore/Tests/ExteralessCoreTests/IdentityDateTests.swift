import Foundation
import XCTest
@testable import ExteralessCore

final class IdentityDateTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let persian = IdentityDatePolicy(usePersianCalendar: true)
    private let latin = IdentityDatePolicy(usePersianCalendar: true, latin: true)

    private func gregorian(_ year: Int, _ month: Int, _ day: Int) -> Date {
        IdentityDatePolicy.gregorianDate(year: year, month: month, day: day, timeZone: utc)!
    }

    func testNowruzLeapAndPost2029ConversionGoldens() {
        // Independent civil-date vectors, also checked with .NET PersianCalendar.
        let vectors = [
            (1989, 3, 21, 1368, 1, 1), (2020, 3, 20, 1399, 1, 1),
            (2021, 3, 20, 1399, 12, 30), (2021, 3, 21, 1400, 1, 1),
            (2024, 3, 19, 1402, 12, 29), (2024, 3, 20, 1403, 1, 1),
            (2025, 3, 20, 1403, 12, 30), (2025, 3, 21, 1404, 1, 1),
            (2029, 3, 20, 1408, 1, 1), (2030, 3, 20, 1408, 12, 30),
            (2030, 3, 21, 1409, 1, 1)
        ]
        for (gy, gm, gd, py, pm, pd) in vectors {
            let date = gregorian(gy, gm, gd)
            let expected = IdentityCalendarDate(year: py, month: pm, day: pd, hour: 12)
            XCTAssertEqual(IdentityDatePolicy.components(at: date, timeZone: utc), expected)
            XCTAssertEqual(IdentityDatePolicy.date(from: expected, timeZone: utc), date)
        }
    }

    func testInvalidDatesAreRejectedRatherThanNormalized() {
        for date in [IdentityCalendarDate(year: 1400, month: 12, day: 30), .init(year: 1403, month: 7, day: 31), .init(year: 1403, month: 13, day: 1), .init(year: 0, month: 1, day: 1), .init(year: 1403, month: 1, day: 1, hour: 24)] {
            XCTAssertNil(IdentityDatePolicy.date(from: date, timeZone: utc))
        }
        XCTAssertNil(IdentityDatePolicy.components(at: Date(timeIntervalSince1970: .infinity), timeZone: utc))
        XCTAssertNil(IdentityDatePolicy.components(at: gregorian(100, 1, 1), timeZone: utc))
        XCTAssertNil(IdentityDatePolicy.gregorianDate(year: 2023, month: 2, day: 29, timeZone: utc))
    }

    func testExplicitTimezoneChangesCivilDayAndYearBoundary() {
        let instant = gregorian(2024, 3, 20).addingTimeInterval(-12 * 3600)
        let west = TimeZone(secondsFromGMT: -8 * 3600)!
        XCTAssertEqual(IdentityDatePolicy.components(at: instant, timeZone: utc)?.day, 1)
        XCTAssertEqual(IdentityDatePolicy.components(at: instant, timeZone: west)?.year, 1402)
        XCTAssertEqual(IdentityDatePolicy.components(at: instant, timeZone: west)?.day, 29)
        XCTAssertFalse(persian.sameYear(instant.addingTimeInterval(-1), instant, timeZone: utc))
        XCTAssertTrue(IdentityDatePolicy().sameYear(instant.addingTimeInterval(-1), instant, timeZone: utc))
    }

    func testSemanticFormatsLatinMonthNamesAndDigitsPreserveSuffixes() {
        let date = gregorian(2024, 3, 20)
        XCTAssertEqual(persian.persianText(for: date, style: .monthDay(includeYear: true), timeZone: utc), "۱ فروردین ۱۴۰۳")
        XCTAssertEqual(latin.persianText(for: date, style: .monthDay(includeYear: true), timeZone: utc), "1 Farvardin 1403")
        XCTAssertEqual(latin.persianText(for: date, style: .numeric(dayFirst: false, separator: "/", suffix: " AD label", fullYear: true), timeZone: utc), "01/01/1403 AD label")
        XCTAssertEqual(persian.persianText(for: date, style: .numeric(dayFirst: true, separator: ".", suffix: ".", fullYear: false), timeZone: utc), "۰۱.۰۱.۰۳.")
        XCTAssertEqual(latin.digits(in: "۱۲:٣٤ PM"), "12:34 PM")
        XCTAssertEqual(persian.digits(in: "12:34 PM"), "۱۲:۳۴ PM")
        XCTAssertNil(IdentityDatePolicy().persianText(for: date, style: .year, timeZone: utc))
        XCTAssertEqual(IdentityDatePolicy(latin: true).digits(in: "۱۲:34"), "۱۲:34")
    }

    func testCalendarDayDistanceAcrossDSTAndYearEnd() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let before = IdentityDatePolicy.gregorianDate(year: 2024, month: 3, day: 9, timeZone: zone)!
        let after = IdentityDatePolicy.gregorianDate(year: 2024, month: 3, day: 10, timeZone: zone)!
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 3600)
        XCTAssertEqual(IdentityDatePolicy.dayDistance(from: before, to: after, timeZone: zone), 1)
        XCTAssertEqual(IdentityDatePolicy.dayDistance(from: gregorian(2024, 12, 31), to: gregorian(2025, 1, 1), timeZone: utc), 1)
    }

    func testRangeKeepsActualEndpointsAcrossPersianNewYear() {
        XCTAssertEqual(latin.persianRange(from: gregorian(2024, 3, 19), through: gregorian(2024, 3, 20), timeZone: utc), "29 Esfand 1402 – 1 Farvardin 1403")
        XCTAssertEqual(latin.persianRange(from: gregorian(2024, 3, 20), through: gregorian(2024, 3, 20), timeZone: utc), "1 Farvardin 1403")
        XCTAssertNil(latin.persianRange(from: gregorian(2024, 3, 20), through: gregorian(2024, 3, 19), timeZone: utc))
    }
}
