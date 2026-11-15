import Foundation

/// The root's no-Host proof and its schema freeze have the same one-shot finish
/// semantics as a native lease. A cancelled observer cannot abandon that cleanup.
@MainActor final class PluginRuntimeMaintenanceCompletion {
    private var decision: Bool?
    private var operation: Task<Void, Error>?

    func finish(recovered: Bool, body: @escaping @MainActor () async throws -> Void) async throws {
        if let decision, let operation {
            guard decision == recovered else { throw PluginUIFailure.unavailable("Maintenance lease already has a different finish decision") }
            try await operation.value
            return
        }
        self.decision = recovered
        let operation = Task { @MainActor in try await body() }
        self.operation = operation
        try await operation.value
    }
}
