import Foundation
import XCTest
@testable import ExteralessCore

final class CloudRemoteTests: XCTestCase, @unchecked Sendable {
    func testOriginalBotStorageCodecUsesActualMethodsAndNullSemantics() async throws {
        let rpc = CloudFixtureBotRPC()
        let storage = CloudBotStorageTransport { try await rpc.invoke($0, $1) }
        let key = CloudProtocol.chunkKey(UUID(), 0)
        try await storage.set(key: key, value: "fixture \"quoted\" value")
        let keys = try await storage.keys()
        let values = try await storage.get([key, "neko_settings"])
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(values, [key: "fixture \"quoted\" value"])
        try await storage.remove([key])
        let removed = try await storage.get([key])
        XCTAssertTrue(removed.isEmpty)
        let calls = await rpc.transcript()
        XCTAssertEqual(calls.map(\.method), ["saveStorageValue", "getStorageKeys", "getStorageValues", "deleteStorageValues", "getStorageValues"])
        XCTAssertEqual(String(decoding: calls[1].params, as: UTF8.self), "{}")
        XCTAssertEqual(CloudProtocol.botName, "exteralesscloudbot")
        XCTAssertEqual(CloudProtocol.botId, 8_856_509_355)
        XCTAssertEqual(CloudProtocol.chunkCharacters, 3_000)
        XCTAssertEqual(CloudProtocol.batchSize, 50)
    }

    func testUnsupportedKeysAndOversizedBatchesFailBeforeRPC() async throws {
        let rpc = CloudFixtureBotRPC()
        let storage = CloudBotStorageTransport { try await rpc.invoke($0, $1) }
        do { try await storage.set(key: "neko_settings", value: "overwrite"); XCTFail("Legacy writes must not be admitted") } catch {}
        do { try await storage.remove(["unrelated"]); XCTFail("Unrelated deletion must not be admitted") } catch {}
        do { _ = try await storage.get((0...50).map { "neko_settings_\($0)" }); XCTFail("Oversized batch must fail") } catch {}
        let calls = await rpc.transcript()
        XCTAssertTrue(calls.isEmpty)
    }

    func testVersionedChunkPublicationVerifiesDataAndCommitsManifestLast() async throws {
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let payload = Data(repeating: 65, count: 6_010)
        let revision = try await remote.publish(payload, expectedHeads: [], date: CloudFixture.date)
        let read = try await remote.read(revision)
        let catalog = try await remote.catalog()
        let writes = await transport.writes()
        XCTAssertEqual(read, payload)
        XCTAssertEqual(revision.chunks, 3)
        XCTAssertEqual(writes.last, CloudProtocol.manifestKey(revision.id))
        XCTAssertEqual(catalog.heads, [revision.id])
        XCTAssertEqual(revision.encoding, "gzip_base64_v1")
        XCTAssertEqual(revision.sha256, ToolsSHA256.hex(payload))
    }

    func testFailedChunkAndStaleRevisionCannotPublishACommit() async throws {
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        await transport.failWrite(at: 2)
        do { _ = try await remote.publish(Data(repeating: 65, count: 6_010), expectedHeads: []); XCTFail("Injected write failure") }
        catch { XCTAssertEqual(error as? CloudError, .network) }
        let incomplete = try await remote.catalog()
        XCTAssertTrue(incomplete.heads.isEmpty)
        await transport.failWrite(at: nil)
        let revision = try await remote.publish(Data("complete".utf8), expectedHeads: [], date: CloudFixture.date)
        let count = await transport.writes().count
        do { _ = try await remote.publish(Data("stale".utf8), expectedHeads: []); XCTFail("Expected revision conflict") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        let after = try await remote.catalog()
        let finalCount = await transport.writes().count
        XCTAssertEqual(after.heads, [revision.id])
        XCTAssertEqual(count, finalCount)
    }

    func testConcurrentDevicesLeaveBothHeadsAndRequireExplicitResolution() async throws {
        let transport = CloudFixtureTransport()
        await transport.holdTwoManifestWrites()
        let first = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let second = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let a = Task { () -> CloudError? in
            do { _ = try await first.publish(Data("device-a".utf8), expectedHeads: [], date: CloudFixture.date); return nil }
            catch { return error as? CloudError }
        }
        let b = Task { () -> CloudError? in
            do { _ = try await second.publish(Data("device-b".utf8), expectedHeads: [], date: CloudFixture.date); return nil }
            catch { return error as? CloudError }
        }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 1_000_000_000); a.cancel(); b.cancel() } catch {}
        }
        defer { deadline.cancel() }
        let errors = await [a.value, b.value]
        XCTAssertEqual(errors, [.conflict, .conflict])
        let catalog = try await first.catalog()
        XCTAssertEqual(catalog.heads.count, 2)
        var payloads = Set<Data>()
        for revision in catalog.headRevisions { payloads.insert(try await first.read(revision)) }
        XCTAssertEqual(payloads, [Data("device-a".utf8), Data("device-b".utf8)])
        let merged = try await first.publish(Data("reviewed".utf8), expectedHeads: catalog.heads, date: CloudFixture.date)
        let after = try await first.catalog()
        XCTAssertEqual(after.heads, [merged.id])
        XCTAssertEqual(Set(merged.parents), catalog.heads)
        XCTAssertEqual(after.revisions.count, 3)
    }

    func testChecksumsWrongOwnerAndInflationCeilingRejectRemoteInput() async throws {
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let revision = try await remote.publish(Data("fixture".utf8), expectedHeads: [], date: CloudFixture.date)
        await transport.replace(key: CloudProtocol.chunkKey(revision.id, 0), value: Data("changed".utf8).base64EncodedString())
        do { _ = try await remote.read(revision); XCTFail("Expected checksum failure") }
        catch { XCTAssertEqual(error as? CloudError, .checksumMismatch) }
        let other = CloudRemoteStore(owner: .init(userId: 77, environment: .test), transport: transport, compression: CloudFixture.compression)
        do { _ = try await other.catalog(); XCTFail("Expected account isolation") }
        catch { XCTAssertEqual(error as? CloudError, .wrongAccount) }
        await transport.replace(key: CloudProtocol.chunkKey(revision.id, 0), value: Data("fixture".utf8).base64EncodedString())
        let badCodec = CloudCompression(compress: { $0 }, decompress: { _, limit in Data(repeating: 0, count: limit + 1) })
        let bounded = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: badCodec)
        do { _ = try await bounded.read(revision); XCTFail("Expected inflation ceiling") }
        catch { XCTAssertEqual(error as? CloudError, .sizeLimit) }
    }

    func testLegacyChunksAreReadOnlyAndNativeDeleteRetainsOtherNamespaces() async throws {
        let transport = CloudFixtureTransport()
        let original = Data("{\"nkmrcfg\":{\"fixture\":true}}".utf8)
        await transport.seed(["neko_settings": "1", "neko_settings_0": original.base64EncodedString(),
            "neko_settings_encoding": "gzip_base64_v1", "neko_settings_updated_at": "1234", "another_mini_app": "retained"])
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let legacy = try await remote.readAndroidArchive()
        XCTAssertEqual(legacy, original)
        let revision = try await remote.publish(Data("native".utf8), expectedHeads: [], date: CloudFixture.date)
        try await remote.deleteNativeHistory(expectedHeads: [revision.id])
        let remaining = await transport.snapshot()
        XCTAssertEqual(remaining["neko_settings_0"], original.base64EncodedString())
        XCTAssertEqual(remaining["another_mini_app"], "retained")
        XCTAssertFalse(remaining.keys.contains { $0.hasPrefix(CloudProtocol.nativePrefix) })
    }

    func testCycleMissingParentAndFutureSchemaCannotBeMistakenForEmptyCloud() async throws {
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let a = UUID(), b = UUID()
        func manifest(_ id: UUID, parents: [UUID], version: Int = 1) throws -> String {
            let revision = CloudRevision(version: version, id: id, parents: parents, owner: CloudFixture.owner,
                createdAtMilliseconds: 1, encoding: CloudProtocol.encoding, chunks: 1, encodedCharacters: 4,
                sha256: String(repeating: "a", count: 64))
            return String(decoding: try CloudProtocol.encode(revision), as: UTF8.self)
        }
        await transport.seed([CloudProtocol.manifestKey(a): try manifest(a, parents: [b]), CloudProtocol.manifestKey(b): try manifest(b, parents: [a])])
        do { _ = try await remote.catalog(); XCTFail("Cycle must fail") } catch { XCTAssertEqual(error as? CloudError, .malformedRemote) }
        await transport.seed([CloudProtocol.manifestKey(a): try manifest(a, parents: [b])])
        do { _ = try await remote.catalog(); XCTFail("Missing parent must fail") } catch { XCTAssertEqual(error as? CloudError, .malformedRemote) }
        try await remote.deleteDamagedNativeData()
        let repaired = try await remote.catalog()
        XCTAssertTrue(repaired.heads.isEmpty)
        await transport.seed([CloudProtocol.manifestKey(a): try manifest(a, parents: [], version: 2)])
        do { _ = try await remote.catalog(); XCTFail("Future schema must fail") } catch { XCTAssertEqual(error as? CloudError, .unsupportedVersion) }
    }
}
