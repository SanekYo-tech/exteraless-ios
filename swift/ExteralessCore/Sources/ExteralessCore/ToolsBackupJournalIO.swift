import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ToolsBackupJournalIO {
    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            try synchronizeDirectory(url.deletingLastPathComponent())
        } catch let failure as ToolsBackupWriteFailure { throw failure }
        catch { throw ToolsBackupWriteFailure.durability("The backup recovery record could not be persisted (code \((error as NSError).code)).") }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw ToolsBackupWriteFailure.durability("Could not open the recovery directory for synchronization.") }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ToolsBackupWriteFailure.durability("The recovery directory could not be synchronized.") }
        #elseif canImport(Glibc)
        let descriptor = url.path.withCString { Glibc.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw ToolsBackupWriteFailure.durability("Could not open the recovery directory for synchronization.") }
        defer { _ = Glibc.close(descriptor) }
        guard Glibc.fsync(descriptor) == 0 else { throw ToolsBackupWriteFailure.durability("The recovery directory could not be synchronized.") }
        #else
        throw ToolsBackupWriteFailure.durability("Durable directory synchronization is unavailable on this platform.")
        #endif
    }
}
