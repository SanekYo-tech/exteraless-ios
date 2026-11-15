import ExteralessCore
import Foundation
import MtProtoKit

/// DNS-SD is asynchronous and its service is deallocated on cancellation. It also
/// preserves iOS split DNS / mDNS / DNS64, unlike a detached getaddrinfo thread.
final class ExteralessSystemDNS: NetworkResolverSystemLookup, @unchecked Sendable {
    func lookup(_ question: NetworkDNSQuestion, completion: @escaping @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        let disposable = MTAppNetworkResolver.systemQuery(question.name, type: question.type.rawValue).start(next: { value in
            guard let values = value as? [[String: Any]], values.count <= 64 else { completion(.failure(.malformedResponse)); return }
            var records: [NetworkDNSRecord] = []
            for entry in values {
                guard let data = entry["data"] as? Data, let ttl = entry["ttl"] as? NSNumber else { completion(.failure(.malformedResponse)); return }
                let value: NetworkDNSRecord.Value
                switch question.type {
                case .a, .aaaa:
                    let bytes = Array(data)
                    let index = (entry["interfaceIndex"] as? NSNumber)?.uint32Value ?? 0
                    let scope = bytes.count == 16 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && index > 0 ? String(index) : nil
                    guard data.count == (question.type == .a ? 4 : 16), let ip = NetworkIPAddress(bytes: bytes, scope: scope) else { completion(.failure(.malformedResponse)); return }
                    value = .address(ip)
                case .txt:
                    let bytes = Array(data)
                    var parts: [Data] = [], offset = 0
                    while offset < bytes.count {
                        let size = Int(bytes[offset]); offset += 1
                        guard offset + size <= bytes.count else { completion(.failure(.malformedResponse)); return }
                        parts.append(Data(bytes[offset..<(offset + size)])); offset += size
                    }
                    value = .text(parts)
                default: completion(.failure(.unsupportedResponse)); return
                }
                records.append(.init(name: question.name, ttl: ttl.uint32Value, value: value))
            }
            completion(.success(.init(records: records, canonicalName: question.name, ttl: Double(records.map(\.ttl).min() ?? 0), negative: records.isEmpty ? .noRecords : nil)))
        }, error: { _ in completion(.failure(.transport)) }, completed: {})
        return NetworkResolverCancellation { disposable?.dispose() }
    }
}
