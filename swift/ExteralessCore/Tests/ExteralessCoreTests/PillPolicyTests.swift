import Foundation
import XCTest
@testable import ExteralessCore

final class PillTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}

struct PillTestSecretStore: ClientSecretStore {
    func data(for key: String) throws -> Data? { throw ClientSettingsError.secretAccessDenied }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretAccessDenied }
}

extension XCTestCase {
    func pillSettings() throws -> ClientSettings {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pills-own-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let settings = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"), secretStore: PillTestSecretStore())
        try settings.register(ChatFeatures.definitions + PillFeatures.definitions)
        return settings
    }
}

final class PillPolicyTests: XCTestCase {
    func testRegistryContainsEveryOriginalIdAndKeepsOriginalDefaults() throws {
        let settings = try pillSettings()
        let config = try PillConfiguration(values: settings.snapshot())
        XCTAssertEqual(PillRegistry.descriptors(configuration: config).map(\.id), Array(1...15))
        XCTAssertEqual(config.layout.active, [5, 6])
        XCTAssertTrue(config.layout.loop)
        XCTAssertTrue(config.usesCurrentLocation)
        XCTAssertNil(config.coordinate)
        XCTAssertEqual(PillRegistry.descriptors(configuration: config).first { $0.id == 2 }?.pair, PillRatePair(base: "TON", target: "AUTO"))
        XCTAssertTrue(Set(PillFeatures.definitions.map(\.key)).isDisjoint(with: ["chats.activePillsRaw", "chats.hiddenPillsRaw", "chats.lastActivePillId", "chats.infiniteScrolling"]))
    }

    func testDormantIdsAndHiddenSelectionSurviveReorderAndLoop() throws {
        var layout = PillLayout(active: [5, 9001, 3, 6, 5], hidden: [3], selected: 3)
        let available: Set<Int> = [3, 5, 6]
        XCTAssertEqual(layout.visible(available: available), [5, 6])
        XCTAssertEqual(layout.selection(available: available), 5)
        XCTAssertEqual(layout.next(current: 6, available: available, forward: true), 5)
        layout.loop = false
        XCTAssertEqual(layout.next(current: 6, available: available, forward: true), 6)
        try layout.reorder([6, 5], available: available)
        XCTAssertEqual(layout.active, [6, 9001, 3, 5])
        layout.setActive(3, enabled: true)
        XCTAssertEqual(layout.visible(available: available), [6, 5, 3])
        XCTAssertEqual(layout.visible(available: available.union([9001])), [6, 9001, 5, 3])
    }

    func testLegacyRatesMigrateAsOneDurableGenerationIncludingSelection() throws {
        let settings = try pillSettings()
        try settings.applyPublic([
            "chats.activePillsRaw": .string("5,2,9999,3"), "chats.hiddenPillsRaw": .string("14"),
            "chats.lastActivePillId": .integer(2), "chats.gramTargetCurrency": .string("RUB"),
            "chats.btcTargetCurrency": .string("EUR"), "chats.rateInstancesRaw": .string("100:USD>EUR")
        ])
        let seen = PillTestBox<[[String: ClientSettingValue]]>([])
        let observer = settings.observe { _ in seen.update { $0.append(settings.snapshot()) } }
        defer { observer.cancel() }
        let store = PillSettingsStore(settings: settings)
        try store.migrateLegacyRates()
        XCTAssertEqual(seen.read().count, 1)
        let config = try PillConfiguration(values: settings.snapshot())
        XCTAssertEqual(config.layout.active, [5, 101, 9999, 102])
        XCTAssertEqual(config.layout.hidden, [103])
        XCTAssertEqual(config.layout.selected, 101)
        XCTAssertEqual(config.instances.first { $0.id == 101 }?.pair, PillRatePair(base: "TON", target: "RUB"))
        XCTAssertEqual(config.instances.first { $0.id == 102 }?.pair, PillRatePair(base: "BTC", target: "EUR"))
        try store.migrateLegacyRates()
        XCTAssertEqual(seen.read().count, 1, "Migration is idempotent")
    }

    func testFailedMigrationDoesNotSetMarkerOrDiscardLayout() throws {
        let settings = try pillSettings()
        try settings.applyPublic(["chats.activePillsRaw": .string("2,5"), "chats.gramTargetCurrency": .string("invalid")])
        let before = settings.snapshot()
        XCTAssertThrowsError(try PillSettingsStore(settings: settings).migrateLegacyRates())
        XCTAssertEqual(settings.snapshot(), before)
        XCTAssertFalse(settings.bool("chats.rateInstancesMigrated"))
    }

    func testCapacityPreservesExecutableLegacyIdsAndMalformedInstances() throws {
        let settings = try pillSettings()
        let instances = (100..<112).map { PillRateInstance(id: $0, pair: .init(base: "BTC", target: "USD")) }
        try settings.applyPublic(["chats.rateInstancesRaw": .string(PillRateInstance.serialize(instances)), "chats.activePillsRaw": .string("2,5")])
        let store = PillSettingsStore(settings: settings)
        try store.migrateLegacyRates()
        XCTAssertEqual(try PillConfiguration(values: settings.snapshot()).layout.active, [2, 5])
        XCTAssertThrowsError(try store.addRate(pair: .init(base: "EUR", target: "USD")))
        XCTAssertThrowsError(try PillRateInstance.parse("100:BTC>USD;100:EUR>USD"))
        XCTAssertThrowsError(try PillRateInstance.parse("100:BTC>USD;"))
        XCTAssertEqual(try PillRateInstance.parse("100:GRAM>RUB").first?.pair.base, "TON")
    }

    func testPairEditRejectsStaleScreenAndRemovalIsAtomic() throws {
        let settings = try pillSettings()
        let store = PillSettingsStore(settings: settings)
        let initial = PillRatePair(base: "BTC", target: "USD")
        let id = try store.addRate(pair: initial)
        try store.setPair(id: id, pair: .init(base: "ETH", target: "EUR"), expectedPair: initial)
        XCTAssertThrowsError(try store.setPair(id: id, pair: .init(base: "BTC", target: "RUB"), expectedPair: initial))
        try settings.set(.integer(Int64(id)), for: "chats.lastActivePillId")
        try store.removeRate(id: id)
        let config = try PillConfiguration(values: settings.snapshot())
        XCTAssertTrue(config.instances.isEmpty)
        XCTAssertFalse(config.layout.active.contains(id))
        XCTAssertEqual(config.layout.selected, -1)
    }

    func testManualLocationValidationAndAtomicModeChange() throws {
        let settings = try pillSettings()
        let store = PillSettingsStore(settings: settings)
        XCTAssertThrowsError(try PillCoordinate(latitude: .nan, longitude: 0))
        XCTAssertThrowsError(try PillCoordinate(latitude: 0, longitude: 181))
        let point = try PillCoordinate(latitude: -12.125, longitude: 76.625)
        let seen = PillTestBox(0)
        let observation = settings.observe { _ in
            let config = try? PillConfiguration(values: settings.snapshot())
            XCTAssertEqual(config?.coordinate, point)
            XCTAssertEqual(config?.usesCurrentLocation, false)
            seen.update { $0 += 1 }
        }
        defer { observation.cancel() }
        try store.setWeather(coordinate: point, address: "Fixture place")
        XCTAssertEqual(seen.read(), 1)
    }

    func testMetricIntervalsRejectResetsAndBackgroundGapsWithoutInventingZero() {
        XCTAssertNil(PillMetricPolicy.processCPU(previous: nil, current: .init(uptime: 100, processSeconds: 10), processors: 8))
        XCTAssertEqual(PillMetricPolicy.processCPU(previous: .init(uptime: 100, processSeconds: 10), current: .init(uptime: 103, processSeconds: 14.5), processors: 8), 150)
        XCTAssertNil(PillMetricPolicy.processCPU(previous: .init(uptime: 100, processSeconds: 10), current: .init(uptime: 200, processSeconds: 14.5), processors: 8))
        XCTAssertNil(PillMetricPolicy.processCPU(previous: .init(uptime: 100, processSeconds: 10), current: .init(uptime: 103, processSeconds: .infinity), processors: 8))
        let old = PillNetworkCounters(uptime: 100, received: 1000, sent: 400, resetIdentity: "one")
        let next = PillNetworkCounters(uptime: 102, received: 3000, sent: 600, resetIdentity: "one")
        let speed = PillMetricPolicy.networkSpeed(previous: old, current: next)
        XCTAssertEqual(speed?.received, 1000); XCTAssertEqual(speed?.sent, 100)
        XCTAssertNil(PillMetricPolicy.networkSpeed(previous: next, current: .init(uptime: 104, received: 1, sent: 1, resetIdentity: "two")))
        XCTAssertNil(PillMetricPolicy.freeMemory(bytes: 1001, total: 1000))
        XCTAssertEqual(PillMetricPolicy.freeMemory(bytes: 0, total: 1000), 0, "A measured zero is valid; an unavailable reading is nil")
        XCTAssertNil(PillMetricPolicy.occupiedFraction(total: 0, free: 0))
    }

    func testOriginalEndpointsCurrencyDirectionAndFreshness() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let table = try PillRateTable.parseCoinbase(Data(#"{"data":{"currency":"USD","rates":{"USD":"1","BTC":"0.00002","EUR":"0.8","TON":"0.25"}}}"#.utf8), now: date)
        XCTAssertEqual(table.rate(base: "BTC", target: "EUR"), 40_000)
        XCTAssertEqual(table.rate(base: "TON", target: "USD"), 4)
        XCTAssertEqual(PillRateTable.cached(table.serialized, milliseconds: 1_000_000), table)
        XCTAssertNil(PillCurrencies.decimal("-1")); XCTAssertNil(PillCurrencies.decimal("nan")); XCTAssertNil(PillCurrencies.decimal("1invalid"))
        XCTAssertEqual(PillCurrencies.resolve("AUTO", phoneCountry: "KZ"), "KZT")
        XCTAssertEqual(PillCurrencies.resolve("AUTO", phoneCountry: nil), "USD")
        XCTAssertFalse(PillFreshness.isFresh(date, now: date.addingTimeInterval(-1), ttl: 300))
        XCTAssertFalse(PillFreshness.isFresh(date, now: date.addingTimeInterval(300), ttl: 300))
        XCTAssertEqual(PillEndpoints.coinbase.absoluteString, "https://api.coinbase.com/v2/exchange-rates?currency=USD")
        XCTAssertEqual(PillEndpoints.gold.absoluteString, "https://api.gold-api.com/price/XAU")
    }

    func testWeatherUnitsValidationAndSourceIdentity() throws {
        let coordinate = try PillCoordinate(latitude: 1, longitude: 2)
        let value = try PillWeatherReading.parseOpenMeteo(Data(#"{"current_weather":{"temperature":68,"weathercode":0,"is_day":0},"current_weather_units":{"temperature":"°F"}}"#.utf8), coordinate: coordinate, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(value.temperatureCelsius, 20)
        XCTAssertEqual(value.temperature(units: "C"), "20°C")
        XCTAssertEqual(value.temperature(units: "F"), "68°F")
        XCTAssertEqual(value.coordinate, coordinate); XCTAssertEqual(value.source, .openMeteo)
        XCTAssertThrowsError(try PillWeatherReading(coordinate: coordinate, celsius: .infinity, emoji: "☀", updatedAt: Date(), source: .telegram))
        XCTAssertThrowsError(try PillWeatherReading.parseOpenMeteo(Data(#"{"current_weather":{"temperature":20,"weathercode":1234},"current_weather_units":{"temperature":"°C"}}"#.utf8), coordinate: coordinate, now: Date()))
    }

    func testPortableSnapshotUsesUnixMillisecondsAndRejectsNonFiniteProgress() throws {
        let model = PillModel(id: 10_001, title: "Fixture", value: "12 MB", source: "fixture", updatedAt: Date(timeIntervalSince1970: 1000.25), progress: 0.25)
        let data = try JSONEncoder().encode(model)
        let object = try JSONDecoder().decode([String: ClientSettingValue].self, from: data)
        XCTAssertEqual(object["updatedAtMs"], .integer(1_000_250))
        XCTAssertNil(object["updatedAt"])
        XCTAssertEqual(try JSONDecoder().decode(PillModel.self, from: data), model)
        var invalid = model; invalid.progress = .infinity
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }
}
