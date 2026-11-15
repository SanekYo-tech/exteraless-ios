import Foundation
import XCTest
@testable import ExteralessCore

#if canImport(Darwin) || canImport(Glibc)
final class ToolsDarwinStorageTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        // Deliberately retain Foundation's actual spelling (Darwin /var/folders).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-os-alias-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testFoundationTempURLReachesActualPreparedJournalAndRetiresIt() throws {
        let root = try root()
        let file = try ToolsFileSafety.checkedChild("fixture.bin", root: root)
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(try ToolsFileSafety.read(root.appendingPathComponent("fixture.bin"), maximumBytes: 3), Data([1, 2, 3]))
        let key = "tools.cameraStabilization"
        let definitions = [ClientSettingDefinition(key: key, title: "Fixture", section: "Fixture", defaultValue: .bool(false))]
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("client.json"), secretStore: NoSecrets())
        try settings.register(definitions)
        let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
        try ToolsBackupPolicy.validateLocation(location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path), "Readonly location validation cannot create the plugin directory")
        let archive = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(.init(createdAt: "2026-11-15T00:00:00Z",
            appVersion: "fixture", clientSettings: [key: .bool(true)])), definitions: definitions)
        let prepared = Flag()
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterPrepared = point {
                prepared.set(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
            }
        })
        _ = try restorer.restore(archive, settings: .clientSettings(settings), plugins: location)
        XCTAssertTrue(prepared.get(), "The fixture must pass the path gate and reach the real journal")
        XCTAssertTrue(settings.bool(key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
    }

    #if canImport(Darwin)
    func testDocumentedDarwinRootAliasesNameTheSamePinnedDirectory() throws {
        for name in ["var", "tmp", "etc"] {
            let alias = try ToolsDirectoryDescriptor.open(URL(fileURLWithPath: "/" + name, isDirectory: true))
            let canonical = try ToolsDirectoryDescriptor.open(URL(fileURLWithPath: "/private/" + name, isDirectory: true))
            XCTAssertEqual(try alias.identity, try canonical.identity)
            try alias.verify()
            try canonical.verify()
        }
        let root = try root()
        let privateRoot = ToolsFileSafety.canonicalFileURL(root)
        let child = try ToolsFileSafety.checkedChild("fixture.bin", root: privateRoot)
        try Data([7]).write(to: child)
        XCTAssertEqual(try ToolsFileSafety.read(root.appendingPathComponent("fixture.bin"), maximumBytes: 1), Data([7]))
        _ = try ToolsFileSafety.checkedPath(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), directory: true)
        let groupLike = root.appendingPathComponent("Library/Group Containers/group.fixture", isDirectory: true)
        let directory = try ToolsDirectoryDescriptor.open(groupLike, create: true)
        try directory.verify()
        XCTAssertNoThrow(try ToolsFileSafety.checkedChild("metadata.json", root: groupLike))
    }
    #endif

    func testDescendantNamedVarOrTmpIsNeverTreatedAsASystemAlias() throws {
        let root = try root(), foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data([9]).write(to: foreign.appendingPathComponent("fixture.bin"))
        for name in ["var", "tmp", "etc"] {
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
            XCTAssertThrowsError(try ToolsFileSafety.checkedChild("fixture.bin", root: link))
            XCTAssertThrowsError(try ToolsDirectoryDescriptor.open(link))
            XCTAssertThrowsError(try ToolsFileSafety.checkedPath(link.appendingPathComponent("missing/leaf.json")))
        }
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("fixture.bin")), Data([9]))
    }

    func testSystemPrefixPinRejectsRetargetAndForeignDirectoryIdentity() throws {
        // Exercise the production prefix validator on an owned miniature root;
        // never modify /var, /tmp, /etc or any user/system directory.
        let root = try root()
        let destination = root.appendingPathComponent("private/var", isDirectory: true)
        let foreign = root.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data([9]).write(to: foreign.appendingPathComponent("foreign.bin"))
        let alias = root.appendingPathComponent("var")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "private/var")
        let descriptor = try ToolsDirectoryDescriptor.open(root)
        let pin = try ToolsSystemAliasPin(root: descriptor, name: "var")
        try pin.verify()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "foreign")
        XCTAssertThrowsError(try pin.verify())
        XCTAssertThrowsError(try ToolsSystemAliasPin(root: descriptor, name: "var"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "private/var")
        let replacementPin = try ToolsSystemAliasPin(root: descriptor, name: "var")
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("retained"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data([8]).write(to: destination.appendingPathComponent("foreign.bin"))
        XCTAssertThrowsError(try replacementPin.verify())
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("foreign.bin")), Data([9]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("foreign.bin")), Data([8]))
    }

    func testAliasRootReadStillRejectsLeafRetargetAtADedicatedQueueBarrier() throws {
        let root = try root(), selected = root.appendingPathComponent("selected.bin"), foreign = root.appendingPathComponent("foreign.bin")
        try Data([1]).write(to: selected)
        try Data([9]).write(to: foreign)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        let hooks = ToolsFileOperationHooks { point, _ in
            if case .afterSourceMetadata = point {
                reached.signal()
                guard release.wait(timeout: .now() + 2) == .success else { throw ToolsError.unavailable("Fixture barrier timed out") }
            }
        }
        DispatchQueue(label: "tools-os-alias-fixture").async {
            defer { done.signal() }
            outcome.set(Result { try ToolsFileSafety.read(selected, maximumBytes: 1, hooks: hooks) })
        }
        // All waits are synchronous, outside an async/actor task. Only the dedicated
        // I/O queue pauses at the hook; the replacement uses self-owned fixture data.
        defer { release.signal() }
        XCTAssertEqual(reached.wait(timeout: .now() + 2), .success)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: foreign)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        let result = try XCTUnwrap(outcome.get())
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? ToolsError, .unsafePath) }
        XCTAssertEqual(try Data(contentsOf: foreign), Data([9]))
    }

    func testHeldDirectoryCleanupUnderFoundationRootPreservesForeignReplacement() throws {
        let root = try root()
        let parent = try ToolsDirectoryDescriptor.open(root)
        let owned = try ToolsOwnedDirectory.create(parent: parent, name: "stage")
        try owned.write(Data([1]), name: "owned.json")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root.appendingPathComponent("stage"), to: moved)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stage"), withIntermediateDirectories: false)
        let foreign = root.appendingPathComponent("stage/foreign.bin")
        try Data([9]).write(to: foreign)
        XCTAssertFalse(owned.cleanup())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: foreign), Data([9]))
    }

    func testEmojiAndCloudStoresAcceptFoundationRootAndRejectDescendantRedirection() async throws {
        let root = try root(), emojiRoot = root.appendingPathComponent("emoji"), cloudRoot = root.appendingPathComponent("cloud")
        let emoji = EmojiPackStore(root: emojiRoot, accountId: 77)
        let pack = try await emoji.store(data: EmojiFontFixture.data, name: "Fixture", fileExtension: "ttf", origin: .imported)
        let readBack = try await EmojiPackStore(root: emojiRoot, accountId: 77).fontData(for: pack)
        XCTAssertEqual(readBack, EmojiFontFixture.data)
        let scope = CloudAccountScope(recordId: 11, userId: 77, environment: .test)
        let state = CloudLocalState(scope: scope, acceptedHeads: [UUID()], lastSuccessfulSyncMilliseconds: 123,
            uploadedContentDigest: String(repeating: "a", count: 64))
        let cloud = try CloudFileStateStorage(directory: cloudRoot)
        try cloud.save(state)
        XCTAssertEqual(try CloudFileStateStorage(directory: cloudRoot).load(scope: scope), state)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let sentinel = foreign.appendingPathComponent("index.json")
        try Data([9]).write(to: sentinel)
        for (name, directory) in [("emoji", emojiRoot), ("cloud", cloudRoot)] {
            try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("retained-" + name))
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: foreign)
        }
        do { _ = try await emoji.list(); XCTFail("Redirected emoji root accepted") }
        catch { XCTAssertEqual(error as? EmojiPackError, .storage) }
        XCTAssertThrowsError(try cloud.load(scope: scope)) { XCTAssertEqual($0 as? CloudError, .localStorage) }
        XCTAssertThrowsError(try cloud.save(state)) { XCTAssertEqual($0 as? CloudError, .localStorage) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
    }

    private struct NoSecrets: ClientSecretStore {
        func data(for key: String) throws -> Data? { XCTFail("No credential reads in an alias fixture"); return nil }
        func set(_ data: Data?, for key: String) throws { XCTFail("No credential writes in an alias fixture") }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock(); private var value: Result<Data, Error>?
        func set(_ value: Result<Data, Error>) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
#endif
