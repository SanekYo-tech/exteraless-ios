import Foundation

public struct PillRateQuote: Equatable, Sendable {
    public let pair: PillRatePair
    public let value: Decimal
    public let updatedAt: Date
    public let source: String
}

public struct PillRateUpdate: Sendable {
    public let quote: PillRateQuote?
    public let isLoading: Bool
    public let error: PillError?
    public let cacheError: String?
}

/// Per-account-generation raw caches; a pair/target is captured by value for each read.
public final class PillRateProvider: @unchecked Sendable {
    private let lease: PillAccountLease
    private let settings: ClientSettings
    public let http: PillHTTPClient
    private let queue = DispatchQueue(label: "Exteraless.Pills.Rates", qos: .utility)
    private let lock = NSLock()
    private var table: PillRateTable?
    private var gold: PillGoldPrice?
    private var cacheError: String?
    private let ratesPool = PillRequestPool<PillRateTable>()
    private let goldPool = PillRequestPool<PillGoldPrice>()
    private let now: @Sendable () -> Date

    public init(lease: PillAccountLease, settings: ClientSettings, http: PillHTTPClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lease = lease; self.settings = settings; self.http = http; self.now = now
        let values = settings.snapshot()
        func text(_ key: String) -> String { if case let .string(value)? = values[key] { return value }; return "" }
        func time(_ key: String) -> Int64 { if case let .integer(value)? = values[key] { return value }; return 0 }
        table = PillRateTable.cached(text("chats.ratesCache"), milliseconds: time("chats.ratesCacheTime"))
        if let date = PillFreshness.date(milliseconds: time("chats.goldPriceCacheTime")), let value = PillCurrencies.decimal(text("chats.goldPriceCache")) {
            gold = try? .init(value: value, updatedAt: date)
        }
    }

    public func cancel() { ratesPool.cancel(scope: lease.scope); goldPool.cancel(scope: lease.scope) }

    public func read(pair: PillRatePair, phoneCountry: String?, force: Bool = false,
                     update: @escaping @Sendable (PillRateUpdate) -> Void) -> PillCancellation {
        let operation = PillCancellation()
        let pair = PillRatePair(base: pair.base, target: PillCurrencies.resolve(pair.target, phoneCountry: phoneCountry))
        queue.async { [weak self] in
            guard let self, self.lease.isValid, !operation.isCancelled else { return }
            do { try pair.validate() } catch { update(.init(quote: nil, isLoading: false, error: .invalidConfiguration, cacheError: nil)); return }
            let cached = self.quote(pair)
            if !force, let cached, PillFreshness.isFresh(cached.updatedAt, now: self.now(), ttl: 300) {
                update(self.state(quote: cached, loading: false, error: nil)); return
            }
            update(self.state(quote: cached, loading: true, error: nil))
            let count = pair.base == "XAU" && pair.target != "USD" ? 2 : 1
            let group = PillRateCompletion(count: count) { [weak self] error in
                guard let self, self.lease.isValid, !operation.isCancelled else { return }
                let quote = self.quote(pair)
                update(self.state(quote: quote, loading: false, error: error ?? (quote == nil ? .unsupportedCurrency : nil)))
            }
            if pair.base != "XAU" || pair.target != "USD" {
                operation.add(self.loadRates(force: force) { result in group.complete(result.failure) })
            }
            if pair.base == "XAU" {
                operation.add(self.loadGold(force: force) { result in group.complete(result.failure) })
            }
        }
        return operation
    }

    private func state(quote: PillRateQuote?, loading: Bool, error: PillError?) -> PillRateUpdate {
        lock.lock(); let cacheError = self.cacheError; lock.unlock()
        return .init(quote: quote, isLoading: loading, error: error, cacheError: cacheError)
    }
    private func quote(_ pair: PillRatePair) -> PillRateQuote? {
        lock.lock(); defer { lock.unlock() }
        if pair.base == "XAU" {
            guard let gold else { return nil }
            if pair.target == "USD" { return .init(pair: pair, value: gold.usdPerTroyOunce, updatedAt: gold.updatedAt, source: "gold-api.com · USD / troy oz") }
            guard let table, let target = table.usdPerUnit[pair.target], let value = PillCurrencies.divide(gold.usdPerTroyOunce, target) else { return nil }
            return .init(pair: pair, value: value, updatedAt: min(table.updatedAt, gold.updatedAt), source: "gold-api.com + Coinbase · per troy oz")
        }
        guard let table, let value = table.rate(base: pair.base, target: pair.target) else { return nil }
        return .init(pair: pair, value: value, updatedAt: table.updatedAt, source: "Coinbase · per \(pair.base)")
    }

    private func loadRates(force: Bool, completion: @escaping PillRequestPool<PillRateTable>.Completion) -> PillCancellation {
        lock.lock(); let cached = table; lock.unlock()
        if !force, let cached, PillFreshness.isFresh(cached.updatedAt, now: now(), ttl: 300) { completion(.success(cached)); return PillCancellation() }
        return ratesPool.request(key: .init(scope: lease.scope, domain: "rates", selection: "coinbase.USD"), start: { [weak self] finish in
            guard let self, self.lease.isValid else { finish(.failure(.cancelled)); return PillCancellation() }
            let work = PillCancellation()
            work.add(self.http.get(PillEndpoints.coinbase, domain: "rates") { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self, self.lease.isValid, !work.isCancelled else { return }
                    do {
                        let response = try result.get(); try response.validate(now: self.now())
                        let value = try PillRateTable.parseCoinbase(response.data, now: self.now())
                        try self.lease.withCurrent {
                            self.lock.lock(); self.table = value; self.lock.unlock()
                            self.persist(["chats.ratesCache": .string(value.serialized), "chats.ratesCacheTime": .integer(try PillFreshness.milliseconds(value.updatedAt))])
                        }
                        finish(.success(value))
                    } catch { finish(.failure(error as? PillError ?? .invalidData)) }
                }
            })
            return work
        }, completion: completion)
    }
    private func loadGold(force: Bool, completion: @escaping PillRequestPool<PillGoldPrice>.Completion) -> PillCancellation {
        lock.lock(); let cached = gold; lock.unlock()
        if !force, let cached, PillFreshness.isFresh(cached.updatedAt, now: now(), ttl: 300) { completion(.success(cached)); return PillCancellation() }
        return goldPool.request(key: .init(scope: lease.scope, domain: "gold", selection: "gold-api.XAU.USD"), start: { [weak self] finish in
            guard let self, self.lease.isValid else { finish(.failure(.cancelled)); return PillCancellation() }
            let work = PillCancellation()
            work.add(self.http.get(PillEndpoints.gold, domain: "gold") { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self, self.lease.isValid, !work.isCancelled else { return }
                    do {
                        let response = try result.get(); try response.validate(now: self.now())
                        let value = try PillGoldPrice.parse(response.data, now: self.now())
                        try self.lease.withCurrent {
                            self.lock.lock(); self.gold = value; self.lock.unlock()
                            self.persist(["chats.goldPriceCache": .string(NSDecimalNumber(decimal: value.usdPerTroyOunce).stringValue), "chats.goldPriceCacheTime": .integer(try PillFreshness.milliseconds(value.updatedAt))])
                        }
                        finish(.success(value))
                    } catch { finish(.failure(error as? PillError ?? .invalidData)) }
                }
            })
            return work
        }, completion: completion)
    }
    private func persist(_ values: [String: ClientSettingValue]) {
        do {
            try settings.applyPublic(values, expected: settings.readSnapshot())
            lock.lock(); cacheError = nil; lock.unlock()
        } catch {
            lock.lock(); cacheError = "Reading received; its disk cache could not be saved."; lock.unlock()
        }
    }
}

private extension Result where Failure == PillError {
    var failure: PillError? { if case let .failure(error) = self { return error }; return nil }
}

private final class PillRateCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var error: PillError?
    private let finish: @Sendable (PillError?) -> Void
    init(count: Int, finish: @escaping @Sendable (PillError?) -> Void) { self.count = count; self.finish = finish }
    func complete(_ error: PillError?) {
        lock.lock()
        guard count > 0 else { lock.unlock(); return }
        count -= 1; self.error = self.error ?? error
        let ready = count == 0; let result = self.error
        lock.unlock()
        if ready { finish(result) }
    }
}
