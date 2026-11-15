import Foundation
import UIKit

@MainActor
extension ClientHarnessSession {
    func loadDomainSourceEvidence() throws {
        guard let url = Bundle.main.url(forResource: "client-ui-domain-sources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["format"] as? String == "exteraless-ui-domain-sources/1",
              let files = manifest["files"] as? [String: String], !files.isEmpty,
              let sha = manifest["sha256"] as? String, sha.count == 64 else {
            throw ClientHarnessFailure(description: "Bazel domain source fingerprint resource is missing/invalid")
        }
        self.report.facts["domainSources"] = manifest
        self.report.journal.record("domain-source-inputs", ["sha256": sha, "count": files.count])
    }
}

/// Stable per-process ordinals, not object addresses. Used to compare actual
/// native cells/nodes across palette and projection updates in recorded probes.
@MainActor
final class ClientHarnessViewIdentities {
    private var next = 1
    private var ids: [ObjectIdentifier: (weak: ClientHarnessWeakView, id: Int)] = [:]
    func id(_ view: UIView) -> Int {
        let key = ObjectIdentifier(view)
        if let old = self.ids[key], old.weak.value === view { return old.id }
        let id = self.next
        self.next += 1
        self.ids[key] = (ClientHarnessWeakView(view), id)
        return id
    }
}

private final class ClientHarnessWeakView {
    weak var value: UIView?
    init(_ view: UIView) { self.value = view }
}
