import Foundation
import PluginHost

/// Only this executable fixture writes the emitted candidate to its own temp
/// directory. Production uses the native FD-authority/Host transaction contract.
@main
struct CandidateProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = try Data(contentsOf: root.appendingPathComponent("owned.elyx"))
        let request = try PluginElyxDeveloperRequest(json: String(contentsOf: root.appendingPathComponent("changes.json"), encoding: .utf8))
        guard request.kind == .changes else { throw PluginElyxDeveloperError.malformed("fixture requires elyx_changes") }
        let candidate = try PluginElyxArchiveCandidate.applying(request.changes, to: source)
        try candidate.write(to: root.appendingPathComponent("candidate.elyx"), options: .withoutOverwriting)
        print("NATIVE_ELYX_CANDIDATE_OK \(source.count) -> \(candidate.count)")
    }
}
