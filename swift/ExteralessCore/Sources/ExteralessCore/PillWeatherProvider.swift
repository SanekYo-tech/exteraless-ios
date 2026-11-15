import Foundation

public struct PillWeatherUpdate: Sendable {
    public let reading: PillWeatherReading?
    public let isLoading: Bool
    public let error: PillError?
}

public final class PillWeatherProvider: @unchecked Sendable {
    public typealias NativeFetch = @Sendable (PillCoordinate, @escaping @Sendable (Result<PillWeatherReading, PillError>) -> Void) -> PillCancellation
    private let lease: PillAccountLease
    private let http: PillHTTPClient
    private let nativeFetch: NativeFetch
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: PillWeatherReading] = [:]
    private let pool = PillRequestPool<PillWeatherReading>()
    private let queue = DispatchQueue(label: "Exteraless.Pills.Weather", qos: .utility)
    public init(lease: PillAccountLease, http: PillHTTPClient, nativeFetch: @escaping NativeFetch,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.lease = lease; self.http = http; self.nativeFetch = nativeFetch; self.now = now
    }
    public func cancel() { pool.cancel(scope: lease.scope) }
    public func read(coordinate: PillCoordinate, source: PillWeatherSource, force: Bool = false,
                     update: @escaping @Sendable (PillWeatherUpdate) -> Void) -> PillCancellation {
        let key = source.rawValue + ":" + coordinate.cacheKey
        let operation = PillCancellation()
        queue.async { [weak self] in
            guard let self, self.lease.isValid, !operation.isCancelled else { return }
            self.lock.lock(); let cached = self.cache[key]; self.lock.unlock()
            if !force, let cached, PillFreshness.isFresh(cached.updatedAt, now: self.now(), ttl: 900) {
                update(.init(reading: cached, isLoading: false, error: nil)); return
            }
            update(.init(reading: cached, isLoading: true, error: nil))
            operation.add(self.pool.request(key: .init(scope: self.lease.scope, domain: "weather", selection: key), start: { [weak self] finish in
                guard let self, self.lease.isValid else { finish(.failure(.cancelled)); return PillCancellation() }
                let work = PillCancellation()
                let accept: @Sendable (Result<PillWeatherReading, PillError>) -> Void = { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self, self.lease.isValid, !work.isCancelled else { return }
                        if case let .success(value) = result {
                            guard value.coordinate == coordinate, value.source == source else { finish(.failure(.invalidData)); return }
                            self.lock.lock()
                            if self.cache.count >= 8, self.cache[key] == nil, let oldest = self.cache.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key { self.cache.removeValue(forKey: oldest) }
                            self.cache[key] = value
                            self.lock.unlock()
                        }
                        finish(result)
                    }
                }
                if source == .telegram {
                    work.add(self.nativeFetch(coordinate, accept))
                } else {
                    work.add(self.http.get(PillEndpoints.openMeteo(coordinate), domain: "weather") { result in
                        do {
                            let response = try result.get(); try response.validate(now: self.now())
                            accept(.success(try PillWeatherReading.parseOpenMeteo(response.data, coordinate: coordinate, now: self.now())))
                        } catch { accept(.failure(error as? PillError ?? .invalidData)) }
                    })
                }
                return work
            }, completion: { [weak self] result in
                guard let self, self.lease.isValid, !operation.isCancelled else { return }
                switch result {
                case let .success(value): update(.init(reading: value, isLoading: false, error: nil))
                case let .failure(error): update(.init(reading: cached, isLoading: false, error: error))
                }
            }))
        }
        return operation
    }
}
