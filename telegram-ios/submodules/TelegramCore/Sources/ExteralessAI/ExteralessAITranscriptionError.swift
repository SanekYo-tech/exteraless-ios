import Foundation

/// UI-facing native transcription failures. The stock callback's `.error` is a
/// failure too; it must never be converted into a successful empty transcript.
public enum ExteralessAITranscriptionError: Error, Equatable, LocalizedError {
    case cancelled
    case configuration
    case notDownloaded
    case sourceChanged
    case nativeFailed
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Transcription cancelled."
        case .configuration: return "Configure the selected transcription provider in Speech settings."
        case .notDownloaded: return "Download this voice message in the chat first, then choose Transcribe."
        case .sourceChanged: return "The message or its protection changed. Open the action again."
        case .nativeFailed: return "Telegram could not transcribe this message."
        case let .failed(message): return message
        }
    }
}
