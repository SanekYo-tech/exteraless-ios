import ExteralessCore
import Foundation
import Postbox

/// Holds only native TempBox handles with explicit account ownership. Panic never
/// enumerates/deletes arbitrary paths, app-group roots or another account's files.
public final class ExteralessPrivacyExtrasTemporaryFiles: @unchecked Sendable {
    public static let shared = ExteralessPrivacyExtrasTemporaryFiles()
    private let lock = NSLock()
    private var files: [PrivacyExtrasAccountIdentity: [ObjectIdentifier: TempBoxFile]] = [:]
    private init() {}

    @discardableResult
    public func track(_ file: EngineTempBox.File, account: PrivacyExtrasAccountIdentity) throws -> EngineTempBox.File {
        lock.lock(); defer { lock.unlock() }
        if files[account]?[ObjectIdentifier(file)] != nil { return file }
        guard files[account, default: [:]].count < 256 else { throw ExteralessHiddenAccountError.capacity }
        // The same native handle cannot be owned by two different accounts.
        guard !files.contains(where: { $0.key != account && $0.value[ObjectIdentifier(file)] != nil }) else { throw ExteralessHiddenAccountError.staleAccount }
        files[account, default: [:]][ObjectIdentifier(file)] = file
        return file
    }

    public func release(_ file: EngineTempBox.File, account: PrivacyExtrasAccountIdentity) {
        lock.lock(); let owned = files[account]?.removeValue(forKey: ObjectIdentifier(file)); lock.unlock()
        if owned != nil { TempBox.shared.dispose(file) }
    }

    public func clear(account: PrivacyExtrasAccountIdentity) {
        lock.lock(); let owned = files.removeValue(forKey: account) ?? [:]; lock.unlock()
        for file in owned.values { TempBox.shared.dispose(file) }
    }
}
