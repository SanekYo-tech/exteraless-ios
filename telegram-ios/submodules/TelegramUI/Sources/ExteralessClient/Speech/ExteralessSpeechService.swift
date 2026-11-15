import AccountContext
@preconcurrency import AVFoundation
import CoreMedia
import ExteralessCore
import Foundation
import TelegramCore
@preconcurrency import Speech
import UniversalMediaPlayer

enum ExteralessSpeechError: Error, LocalizedError {
    case permission, unavailableLanguage, unavailableVoice, usageDescription, duration, decodingTimeout, recognition

    var errorDescription: String? {
        switch self {
        case .permission: return "Allow Speech Recognition for this app in iOS Settings. Audio-file transcription does not require microphone access."
        case .unavailableLanguage: return "On-device recognition is unavailable for this language or device. Download the language in iOS Settings or select a configured cloud provider."
        case .unavailableVoice: return "This speech voice is not installed. Select an available voice in Speech settings."
        case .usageDescription: return "This build is missing NSSpeechRecognitionUsageDescription."
        case .duration: return "Audio limit: 60 seconds for Apple Speech; 180 seconds and 20 MiB decoded WAV for cloud providers."
        case .decodingTimeout: return "Audio decoding exceeded the 30-second local processing limit."
        case .recognition: return "Speech recognition could not complete. Check the selected language and try again."
        }
    }
}

/// One account-owned speech lifetime, with real completion/cancellation callbacks.
/// No AVAudioSession category is changed underneath Telegram calls or recording.
@MainActor
public final class ExteralessSpeechService: NSObject, AVSpeechSynthesizerDelegate {
    private let transport: any AIHTTPTransport
    // The production decoder is real FFmpeg. Loginless native fixtures replace
    // just this data boundary with a bounded PCM file, never account/network state.
    var decodeAudio: @Sendable (URL, Int) async throws -> AIAudioData = { url, seconds in
        try await ExteralessSpeechAudio.decode(fileURL: url, maximumSeconds: seconds)
    }
    var recognitionOverride: (@MainActor (URL, String) async throws -> String)?
    private let synthesizer = AVSpeechSynthesizer()
    private var utteranceId: ObjectIdentifier?
    private var speechCompletion: ((Result<Void, Error>) -> Void)?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionId: UUID?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var recognitionTimeout: Task<Void, Never>?

    public override convenience init() { self.init(transport: AIURLSessionTransport()) }

    public init(transport: any AIHTTPTransport) {
        self.transport = transport
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = false
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking || synthesizer.isPaused }

    public func speak(_ text: String, language: String = "", voiceIdentifier: String = "", rate: Float = AVSpeechUtteranceDefaultSpeechRate, completion: @escaping (Result<Void, Error>) -> Void) throws {
        stopSpeaking()
        guard !text.isEmpty, text.utf16.count <= AILimits.responseUTF16 else { throw AIError.inputTooLarge }
        let voice: AVSpeechSynthesisVoice?
        if !voiceIdentifier.isEmpty { voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) }
        else { voice = AVSpeechSynthesisVoice(language: language.isEmpty ? (NSLinguisticTagger.dominantLanguage(for: text) ?? Locale.current.identifier) : language) }
        guard let voice else { throw ExteralessSpeechError.unavailableVoice }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        utteranceId = ObjectIdentifier(utterance)
        speechCompletion = completion
        synthesizer.speak(utterance)
    }

    public func pauseSpeaking() { synthesizer.pauseSpeaking(at: .word) }
    public func resumeSpeaking() { synthesizer.continueSpeaking() }

    public func stopSpeaking() {
        let completion = speechCompletion
        speechCompletion = nil
        utteranceId = nil
        synthesizer.stopSpeaking(at: .immediate)
        completion?(.failure(AIError.cancelled))
    }

    public func cancelAll() {
        stopSpeaking()
        if let id = recognitionId { finishRecognition(id, result: .failure(AIError.cancelled)) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(id, result: .success(Void())) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(id, result: .failure(AIError.cancelled)) }
    }

    private func finishSpeech(_ id: ObjectIdentifier, result: Result<Void, Error>) {
        guard utteranceId == id else { return }
        let completion = speechCompletion
        speechCompletion = nil
        utteranceId = nil
        completion?(result)
    }

    public func transcribe(fileURL: URL, locale: String, configuration: AITranscriptionConfiguration, transport: (any AIHTTPTransport)? = nil, partial: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String {
        var configuration = configuration
        if case let .provider(provider) = AINativeSpeechPolicy.route(configuration: configuration, isPremium: false) { configuration.provider = provider }
        guard AINativeSpeechPolicy.isConfigured(configuration.provider, configuration: configuration) else { throw ExteralessAITranscriptionError.configuration }
        let native = configuration.provider == .apple
        let audio = try await decodeAudio(fileURL, native ? 60 : 180)
        try Task.checkCancellation()
        if !native { return try await AISpeechHTTPClient(transport: transport ?? self.transport).transcribe(audio: audio, configuration: configuration) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExteralessSpeech-\(UUID().uuidString).wav")
        try audio.data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        if let recognitionOverride { return try await recognitionOverride(url, locale) }
        return try await recognize(url: url, locale: locale, partial: partial)
    }

    private func recognize(url: URL, locale: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        if let id = recognitionId { finishRecognition(id, result: .failure(AIError.cancelled)) }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String, !description.isEmpty else { throw ExteralessSpeechError.usageDescription }
        let id = UUID()
        recognitionId = id
        return try await withTaskCancellationHandler(operation: {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            try Task.checkCancellation()
            guard recognitionId == id else { throw AIError.cancelled }
            guard status == .authorized else { recognitionId = nil; throw ExteralessSpeechError.permission }
            let locale = Locale(identifier: locale.isEmpty ? Locale.current.identifier : locale)
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                recognitionId = nil
                throw ExteralessSpeechError.unavailableLanguage
            }
            self.recognizer = recognizer
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if #available(iOS 16.0, *) { request.addsPunctuation = true }
            return try await withCheckedThrowingContinuation { continuation in
                recognitionContinuation = continuation
                recognitionTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finishRecognition(id, result: .failure(AIError.timeout))
                }
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal ?? false
                    let failed = error != nil
                    Task { @MainActor [weak self] in
                        guard let self, self.recognitionId == id else { return }
                        if let text {
                            partial(text)
                            if final {
                                self.finishRecognition(id, result: text.isEmpty ? .failure(AIError.emptyResponse) : .success(text))
                                return
                            }
                        }
                        if failed { self.finishRecognition(id, result: .failure(ExteralessSpeechError.recognition)) }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finishRecognition(id, result: .failure(AIError.cancelled)) }
        })
    }

    private func finishRecognition(_ id: UUID, result: Result<String, Error>) {
        guard recognitionId == id else { return }
        recognitionId = nil
        let continuation = recognitionContinuation
        recognitionContinuation = nil
        recognitionTimeout?.cancel()
        recognitionTimeout = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        continuation?.resume(with: result)
    }
}

private enum ExteralessSpeechAudio {
    static func decode(fileURL: URL, maximumSeconds: Int) async throws -> AIAudioData {
        let task = Task.detached(priority: .userInitiated) { () throws -> AIAudioData in
            guard fileURL.isFileURL else { throw AIError.invalidAudio }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 50 * 1024 * 1024 else { throw AIError.inputTooLarge }
            // This is Telegram's existing FFmpeg decoder, also used by its media
            // player. Unlike AVURLAsset alone it handles Telegram OGG/Opus voices.
            let source = SoftwareAudioSource(path: fileURL.path)
            guard source.hasStream else { throw AIError.invalidAudio }
            let deadline = Date().addingTimeInterval(30)
            var pcm = Data()
            var sampleRate: UInt32 = 48_000
            while let sample = source.readSampleBuffer() {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ExteralessSpeechError.decodingTimeout }
                guard let description = CMSampleBufferGetFormatDescription(sample), let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      format.pointee.mFormatID == kAudioFormatLinearPCM, format.pointee.mBitsPerChannel == 16,
                      format.pointee.mChannelsPerFrame == 1, format.pointee.mSampleRate == 48_000,
                      let buffer = CMSampleBufferGetDataBuffer(sample) else { throw AIError.invalidAudio }
                sampleRate = UInt32(format.pointee.mSampleRate)
                let count = CMBlockBufferGetDataLength(buffer)
                guard count > 0, pcm.count + count + 44 <= AILimits.audioBytes,
                      pcm.count + count <= maximumSeconds * Int(sampleRate) * 2 else { throw ExteralessSpeechError.duration }
                var bytes = Data(count: count)
                let status = bytes.withUnsafeMutableBytes { destination -> OSStatus in
                    guard let pointer = destination.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: count, destination: pointer)
                }
                guard status == noErr else { throw AIError.invalidAudio }
                pcm.append(bytes)
            }
            try Task.checkCancellation()
            return try AIWaveFile.encode(pcm: pcm, sampleRate: sampleRate)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
