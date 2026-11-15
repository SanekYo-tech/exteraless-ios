import Foundation
import UIKit

struct ClientHarnessFailure: Error, CustomStringConvertible {
    let description: String
}

func clientHarnessRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ClientHarnessFailure(description: message) }
}

func clientHarnessJSON(_ value: Any) throws -> String {
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}

/// Small append-only, synchronized journal. All payloads come from our own
/// fixture; no account/Postbox files, keys, requests or native object addresses.
final class ClientHarnessJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    private var failures: [String] = []
    let started = ProcessInfo.processInfo.systemUptime

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.records.count < 256 else {
            if self.failures.isEmpty { self.failures.append("journal capacity exceeded") }
            return
        }
        var record = fields
        record["event"] = event
        record["elapsed"] = ProcessInfo.processInfo.systemUptime - self.started
        record["wallTime"] = Date().timeIntervalSince1970
        record["mainThread"] = Thread.isMainThread
        self.records.append(record)
    }

    func reject(_ name: String) {
        self.lock.lock()
        self.failures.append(name)
        self.lock.unlock()
        self.record("unexpected-service", ["name": name])
    }

    var snapshot: [[String: Any]] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.records
    }

    var unexpectedServices: [String] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.failures
    }
}

@MainActor
final class ClientHarnessReport {
    let runId: String
    let scenario: String
    let directory: URL
    let journal = ClientHarnessJournal()
    var phase = "starting"
    var probes: [[String: Any]] = []
    var facts: [String: Any] = [:]
    var error: String?

    init(runId: String, scenario: String) throws {
        try clientHarnessRequire(UUID(uuidString: runId) != nil, "invalid run UUID")
        try clientHarnessRequire(ClientHarnessScenario.contains(scenario), "unknown scenario")
        self.runId = runId
        self.scenario = scenario
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.directory = documents.appendingPathComponent("client-ui-harness/" + runId, isDirectory: true)
        try clientHarnessRequire(!FileManager.default.fileExists(atPath: self.directory.path), "run UUID must be fresh")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try self.flush()
    }

    func flush() throws {
        let value: [String: Any] = [
            "format": "exteraless-client-ui-harness/1", "runId": self.runId, "scenario": self.scenario,
            "phase": self.phase, "semanticPassed": self.phase == "completed" && self.error == nil,
            "visualReview": "pending-recorded-frame-review", "error": self.error as Any? ?? NSNull(),
            "driver": "in-process UIKit target/action + table selection + UITextInput; no HID injection",
            "context": "ComposerHarness disposable Account + strict named-trap service fixture",
            "network": "loopback SOCKS5 127.0.0.1:1; platform network effects trap",
            "pythonRequested": self.scenario == "sdk-ui", "facts": self.facts,
            "probes": self.probes, "trace": self.journal.snapshot,
            "unexpectedServices": self.journal.unexpectedServices,
        ]
        try Data(try clientHarnessJSON(value).utf8).write(to: self.directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func fail(_ error: Error) {
        self.phase = "failed"
        self.error = String(describing: error)
        self.journal.record("failed", ["reason": self.error!])
        do { try self.flush() } catch { NSLog("CLIENT_UI_HARNESS_REPORT_WRITE_FAILED %@", String(describing: error)) }
    }
}
