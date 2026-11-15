import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// The adapter's real Signal/Task/lease boundary. Native fixtures replace only
/// account ownership and I/O, so disposing a button exercises this same cancellation.
@MainActor
func exteralessAINativeRequest<Value, Failure>(
    lease: AINativeOperationLease? = nil,
    isCurrent: @escaping @MainActor () -> Bool,
    started: @escaping @MainActor (UUID, AINativeOperationLease) -> Void = { _, _ in },
    ended: @escaping @MainActor (UUID) -> Void = { _ in },
    error mapFailure: @escaping (Error) -> Failure,
    operation: @escaping @MainActor (AINativeOperationLease) async throws -> Value
) -> Signal<Value, Failure> {
    return Signal { subscriber in
        let token = lease ?? AINativeOperationLease()
        let completed = Atomic(value: false)
        let id = UUID()
        let task = Task { @MainActor in
            guard !token.isCancelled, isCurrent() else { subscriber.putError(mapFailure(AIError.cancelled)); return }
            started(id, token)
            defer { ended(id) }
            do {
                let value = try await operation(token)
                guard !Task.isCancelled, !token.isCancelled, isCurrent() else { return }
                _ = completed.swap(true)
                token.bind({})
                subscriber.putNext(value)
                subscriber.putCompletion()
            } catch {
                guard !token.isCancelled, isCurrent() else { return }
                subscriber.putError(mapFailure(error))
            }
        }
        token.bind { task.cancel() }
        return ActionDisposable { if !completed.with({ $0 }) { token.cancel() } }
    }
}

/// Executable selected-provider routing shared by the adapter and round-button
/// fixtures. Provider callbacks receive the resolved configuration, never .auto.
@MainActor
enum ExteralessAINativeTranscriptionRequest {
    static func run(
        configuration: AITranscriptionConfiguration,
        isPremium: Bool,
        telegram: @MainActor () async throws -> Bool,
        provider: @MainActor (AITranscriptionConfiguration) async throws -> Bool
    ) async throws -> Bool {
        var configuration = configuration
        switch AINativeSpeechPolicy.route(configuration: configuration, isPremium: isPremium) {
        case .telegram:
            return try await telegram()
        case let .provider(selected):
            guard AINativeSpeechPolicy.isConfigured(selected, configuration: configuration) else { throw ExteralessAITranscriptionError.configuration }
            configuration.provider = selected
            return try await provider(configuration)
        }
    }
}
