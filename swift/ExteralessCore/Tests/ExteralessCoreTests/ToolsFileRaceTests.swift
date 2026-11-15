import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsFileRaceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-fd-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTB04ExportRefusesLeafSymlinkSubstitutedAfterMetadata() throws {
        let root = try root(), settings = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        let selected = settings.appendingPathComponent("public.json"), other = root.appendingPathComponent("other.json")
        try Data("{\"style\":\"allowed\"}".utf8).write(to: selected)
        try Data("{\"style\":\"foreign-bytes\"}".utf8).write(to: other)
        let hooks = ToolsFileOperationHooks { point, _ in
            if case .afterSourceMetadata = point {
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: other)
            }
        }
        let location = try ToolsSchemaFixture.location(directory: settings, fields: ["public.json": ["style"]])
        XCTAssertThrowsError(try ToolsBackupArchive.export(settings: [:], definitions: [], appVersion: "fixture",
            plugins: location, fileHooks: hooks)) {
            XCTAssertEqual($0 as? ToolsError, .unsafePath)
        }
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "{\"style\":\"foreign-bytes\"}")
    }

    func testTB04ReadAndCopyRejectAncestorReplacementAfterMetadata() throws {
        for copy in [false, true] {
            let root = try root(), sourceFolder = root.appendingPathComponent("source"), other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let selected = sourceFolder.appendingPathComponent("file.bin")
            try Data([1, 2, 3]).write(to: selected)
            try Data([9, 9, 9]).write(to: other.appendingPathComponent("file.bin"))
            let moved = root.appendingPathComponent("moved")
            let hooks = ToolsFileOperationHooks { point, _ in
                if case .afterSourceMetadata = point {
                    try FileManager.default.moveItem(at: sourceFolder, to: moved)
                    try FileManager.default.createSymbolicLink(at: sourceFolder, withDestinationURL: other)
                }
            }
            if copy {
                XCTAssertThrowsError(try ToolsLocalFileSaver.copy(source: selected, destination: root, components: [], name: "output.bin", maximumBytes: 10, hooks: hooks))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output.bin").path))
            } else { XCTAssertThrowsError(try ToolsFileSafety.read(selected, maximumBytes: 10, hooks: hooks)) }
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("file.bin")), Data([1, 2, 3]))
        }
    }

    func testTB04SourceChangedAfterReadIsNotPublished() throws {
        let root = try root(), source = root.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let hooks = ToolsFileOperationHooks { point, _ in
            if case .afterSourceRead = point { try Data([9, 9]).write(to: source) }
        }
        XCTAssertThrowsError(try ToolsLocalFileSaver.copy(source: source, destination: root, components: [], name: "output.bin", maximumBytes: 10, hooks: hooks))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
    }

    func testTB04NoReplacePublicationPreservesRacingCreator() throws {
        let root = try root(), source = root.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let hooks = ToolsFileOperationHooks { point, url in
            if case .beforePublication = point, url.lastPathComponent == "output.bin" { try Data([9]).write(to: url) }
        }
        let saved = try ToolsLocalFileSaver.copy(source: source, destination: root, components: [], name: "output.bin", maximumBytes: 10, hooks: hooks)
        XCTAssertEqual(saved.lastPathComponent, "output (1).bin")
        XCTAssertEqual(try Data(contentsOf: saved), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("output.bin")), Data([9]))
    }

    func testTB04DestinationAncestorSwapLeavesNoOwnedPartialOrForeignOverwrite() throws {
        let root = try root(), source = root.appendingPathComponent("source.bin"), destination = root.appendingPathComponent("target")
        let moved = root.appendingPathComponent("moved")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let hooks = ToolsFileOperationHooks { point, _ in
            if case .beforePublication = point {
                try FileManager.default.moveItem(at: destination, to: moved)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data([9]).write(to: destination.appendingPathComponent("output.bin"))
            }
        }
        XCTAssertThrowsError(try ToolsLocalFileSaver.copy(source: source, destination: destination, components: [], name: "output.bin", maximumBytes: 10, hooks: hooks))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("output.bin")), Data([9]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
}
