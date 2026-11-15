import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ToolsBackupJournalIO {
    static func write(_ data: Data, to url: URL) throws {
        do {
            #if canImport(Darwin) || canImport(Glibc)
            let parent = try ToolsDirectoryDescriptor.open(url.deletingLastPathComponent())
            let previous: ToolsFileMetadata?
            do { previous = ToolsFileMetadata(try parent.metadata(url.lastPathComponent)) }
            catch let error as POSIXError where error.code == .ENOENT { previous = nil }
            let output = try ToolsWriteDescriptor(parent: parent, name: "journal-\(UUID().uuidString).partial")
            defer { output.discard() }
            try output.write(data)
            try output.synchronize()
            try parent.replacePrivateFile(output.name, as: url.lastPathComponent, expected: previous)
            #else
            throw ToolsBackupWriteFailure.durability("Descriptor-bound journal writes are unavailable on this platform.")
            #endif
        } catch let failure as ToolsBackupWriteFailure { throw failure }
        catch { throw ToolsBackupWriteFailure.durability("The backup recovery record could not be persisted (code \((error as NSError).code)).") }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        do { try ToolsDirectoryDescriptor.open(url).synchronize() }
        catch { throw ToolsBackupWriteFailure.durability("The recovery directory could not be synchronized.") }
        #else
        throw ToolsBackupWriteFailure.durability("Durable directory synchronization is unavailable on this platform.")
        #endif
    }
}
