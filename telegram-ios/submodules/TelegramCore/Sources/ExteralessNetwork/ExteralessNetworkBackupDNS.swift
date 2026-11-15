import ExteralessCore
import Foundation
import MtProtoKit

public enum ExteralessNetworkBackupDNS {
    /// Selection is evaluated when discovery subscribes, so changing DNS policy
    /// does not leave the login/account holding its launch-time provider forever.
    public static func backupSignal(context: MTContext, testing: Bool, additionalSource: MTSignal?, phoneNumber: String?, datacenterId: Int) -> MTSignal {
        return MTSignal(generator: { [weak context] subscriber in
            guard let context else { subscriber?.putCompletion(); return MTBlockDisposable(block: {}) }
            return MTBackupAddressSignals.fetchBackupIps(testing, currentContext: context, additionalSource: additionalSource, phoneNumber: phoneNumber, mainDatacenterId: datacenterId, primarySource: source(context: context, testing: testing, phoneNumber: phoneNumber)).start(next: { value in
                subscriber?.putNext(value)
            }, error: { error in subscriber?.putError(error) }, completed: { subscriber?.putCompletion() })
        })
    }

    /// Used instead of the stock Google TXT source only for explicit DoH modes.
    /// The consumer still decodes, time-checks and probes MTProto's signed config.
    public static func source(context: MTContext, testing: Bool, phoneNumber: String?) -> MTSignal? {
        let state = ExteralessNetworkResolverRuntime.shared.resolver.state()
        // A non-nil empty source suppresses the stock public Google TXT source
        // when a persisted custom configuration was rejected at startup.
        guard state.blockedConfiguration == nil else { return MTSignal.complete() }
        let mode = state.mode
        guard mode == .nagramX || mode == .customDoH else { return nil }
        let name = testing ? "tapv3.stel.com" : (context.apiEnvironment.accessHostOverride ?? "apv3.stel.com")
        guard let question = try? NetworkDNSQuestion(name: name, type: .txt) else { return nil }
        return MTSignal(generator: { [weak context] subscriber in
            guard let context else { subscriber?.putCompletion(); return MTBlockDisposable(block: {}) }
            let token = ExteralessNetworkResolverRuntime.shared.resolver.lookup(question) { [weak context] result in
                guard let context, case let .success(answer) = result, answer.negative == nil else { subscriber?.putCompletion(); return }
                let parts = answer.texts.sorted { $0.count > $1.count }
                let encoded = parts.reduce(into: Data()) { $0.append($1) }
                // Original TXT payload is one base64-encoded 256-byte signed blob.
                // Bounds/strict alphabet precede MTProto's existing decoder.
                guard encoded.count <= 1024, let text = String(data: encoded, encoding: .ascii), let data = Data(base64Encoded: text), data.count == 256,
                      let decoded = MTIPDataDecode(context.encryptionProvider, data, phoneNumber ?? ""),
                      Double(decoded.timestamp) < context.globalTime() + 1200,
                      Double(decoded.expirationDate) > context.globalTime() - 1200 else { subscriber?.putCompletion(); return }
                subscriber?.putNext(decoded)
                subscriber?.putCompletion()
            }
            return MTBlockDisposable(block: { token.cancel() })
        })
    }
}
