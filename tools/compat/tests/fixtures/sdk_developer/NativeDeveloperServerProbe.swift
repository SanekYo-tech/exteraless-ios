import Darwin
import Foundation

/// Compiled with the shipping Network listener and wire types, not copies.
@main
struct NativeDeveloperServerProbe {
    struct Failure: Error { let message: String }

    @MainActor
    final class Ledger {
        var calls = 0
        var session: PluginDeveloperSession?
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor
    static func wait(_ reason: String, status: () -> String, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var previous: String?
        while true {
            let complete = predicate()
            let observed = String(status().prefix(2048)).replacingOccurrences(of: "\n", with: "\\n")
            if observed != previous {
                print("SDK_DEVELOPER_NATIVE_STATE \(reason): \(observed)")
                previous = observed
            }
            if complete { return }
            try require(ProcessInfo.processInfo.systemUptime < deadline, "\(reason); actual status: \(observed)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Only called after OUR listener published ready. No request is ever sent
    /// to an unrelated process which already occupies the native fixed port.
    static func exchange(_ request: [String: PluginUIJSON]) throws -> [String: PluginUIJSON] {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try require(socket >= 0, "fixture socket failed: \(errno)")
        defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            try require(setsockopt(socket, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                        "fixture socket timeout failed: \(errno)")
        }
        var noSignal: Int32 = 1
        try require(setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                    "fixture SO_NOSIGPIPE failed: \(errno)")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(42690).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try require(connected == 0, "fixture loopback connect failed: \(errno)")
        let data = Data((try PluginUIJSON.object(request).encoded() + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                try require(sent > 0, "fixture loopback send failed: \(errno)")
                offset += sent
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !received.contains(10) {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, 0) }
            try require(count > 0, "fixture loopback receive failed/closed: \(errno)")
            received.append(contentsOf: buffer.prefix(count))
            try require(received.count <= 16_384, "fixture response exceeded 16 KiB")
        }
        guard let line = PluginDeveloperProtocol.takeLine(from: &received), let text = String(data: line, encoding: .utf8),
              let response = try PluginUIJSON.decode(text).object else {
            throw Failure(message: "fixture response is not a UTF-8 JSON object")
        }
        return response
    }

    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            let message = (error as? Failure)?.message ?? String(describing: error)
            FileHandle.standardError.write(Data(("SDK_DEVELOPER_NATIVE_FAILED " + String(message.prefix(4096)) + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let ledger = Ledger()
        let first = PluginDeveloperServer { request, captured in
            ledger.calls += 1
            ledger.session = captured
            if request["@"] == .string("elyx_changes") {
                // Own native receipt recorder: cancellation AFTER publication
                // must not erase known commit fields at the actual socket edge.
                withUnsafeCurrentTask { $0?.cancel() }
                return ["ok": .bool(false), "plugin_id": .string("7_archive"), "reloaded": .bool(false),
                    "error_kind": .string("StorageError"), "error": .string("owned durability failure"),
                    "errors": .array([.string("owned durability failure")]),
                    "publication_outcome": .string("committed"), "source_changed": .bool(true)]
            }
            return ["pong": .bool(true)]
        }
        let second = PluginDeveloperServer { request, captured in
            ledger.calls += 1
            ledger.session = captured
            return ["pong": .bool(true)]
        }
        defer { first.stop(); second.stop() }
        try require(first.snapshot.token == nil, "stopped listener claimed readiness")
        first.start(tokenDirectory: firstRoot)
        try await wait("own listener readiness within 2s", status: { first.snapshot.status }, until: { first.snapshot.token != nil })
        let firstToken = first.snapshot.token!
        let ping = try await Task.detached { try exchange(["@": .string("ping"), "#": .integer(17)]) }.value
        try require(ping["ok"] == .bool(true) && ping["#"] == .integer(17) && ledger.calls == 1, "free ping framing failed")
        let denied = try await Task.detached {
            try exchange(["@": .string("own_probe"), "token": .string("wrong-own-token")])
        }.value
        try require(denied["ok"] == .bool(false) && ledger.calls == 1, "bad auth reached native handler")
        let committed = try await Task.detached {
            try exchange(["@": .string("elyx_changes"), "plugin_id": .string("7_archive"),
                          "#": .integer(23), "token": .string(firstToken)])
        }.value
        try require(committed["ok"] == .bool(false) && committed["reloaded"] == .bool(false)
            && committed["publication_outcome"] == .string("committed") && committed["source_changed"] == .bool(true)
            && committed["error_kind"] == .string("StorageError") && committed["#"] == .integer(23)
            && committed["errors"] == .array([.string("owned durability failure")]), "post-handler cancellation discarded native publication knowledge")
        let admitted = ledger.calls

        second.start(tokenDirectory: secondRoot)
        try await wait("second owned listener bind failure within 2s", status: { second.snapshot.status }, until: {
            second.snapshot.status.hasPrefix("Developer server failed:") || second.snapshot.status.hasPrefix("Developer server unavailable:")
        })
        try require(second.snapshot.token == nil, "bind failure claimed readiness")
        let retired = ledger.session
        first.stop()
        try require(retired?.isActive == false && first.snapshot.token == nil, "stop did not synchronously revoke the native session")
        try await wait("owned listener retry after port release within 2s", status: { second.snapshot.status }, until: {
            second.start(tokenDirectory: secondRoot)
            return second.snapshot.token != nil
        })
        let nextToken = second.snapshot.token!
        try require(nextToken != firstToken, "retry reused a retired native auth token")
        let expired = try await Task.detached {
            try exchange(["@": .string("own_probe"), "token": .string(firstToken)])
        }.value
        try require(expired["ok"] == .bool(false) && ledger.calls == admitted, "retired token reached replacement listener")
        let allowed = try await Task.detached {
            try exchange(["@": .string("own_probe"), "token": .string(nextToken)])
        }.value
        try require(allowed["ok"] == .bool(true) && ledger.calls == admitted + 1, "current own token failed native auth")
        second.stop()
        try require(ledger.session?.isActive == false && second.snapshot.token == nil, "replacement session was not revoked")
        try await wait("native token file cleanup within 2s", status: { "first=\(first.snapshot.status); second=\(second.snapshot.status)" }, until: {
            !FileManager.default.fileExists(atPath: firstRoot.appendingPathComponent(".devserver_token").path)
                && !FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent(".devserver_token").path)
        })
        print("SDK_DEVELOPER_NATIVE_OK ready_bind_failure_retry_auth_session_revocation_committed_receipt")
    }
}
