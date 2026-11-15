import Foundation
import Postbox
import SwiftSignalKit

private func nativeServiceMessageFile(account: Account, messageId: EngineMessage.Id, fileId: Int64) -> Signal<(Message, TelegramMediaFile), ExteralessTLServiceError> {
    return account.postbox.transaction { transaction -> Result<(Message, TelegramMediaFile), ExteralessTLServiceError> in
        guard let message = transaction.getMessage(messageId) else { return .failure(.local("MESSAGE_NOT_CACHED")) }
        guard !message.isCopyProtected(), message.secretMediaDuration == nil else { return .failure(.local("MEDIA_EXPORT_RESTRICTED")) }
        guard let file = message.effectiveMedia.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.fileId.id == fileId }) else {
            return .failure(.local("MESSAGE_FILE_NOT_FOUND"))
        }
        return .success((message, file))
    }
    |> castError(ExteralessTLServiceError.self)
    |> mapToSignal { result in
        switch result {
        case let .success(value): return .single(value)
        case let .failure(error): return .fail(error)
        }
    }
}

private func nativeServiceFileValue(_ file: TelegramMediaFile) -> ExteralessTLValue {
    return .object([
        "fileId": .integer(file.fileId.id), "resourceId": .string(file.resource.id.stringRepresentation),
        "fileName": file.fileName.map(ExteralessTLValue.string) ?? .null,
        "mimeType": .string(file.mimeType), "size": file.size.map(ExteralessTLValue.integer) ?? .null,
        "isVideo": .bool(file.isVideo), "isVoice": .bool(file.isVoice), "isMusic": .bool(file.isMusic)
    ])
}

/// Reads actual effective media, including native rich-message document blocks.
/// No arbitrary path/URL/resource constructor is accepted from a plugin.
public func nativeServiceMessageMedia(account: Account, messageId: EngineMessage.Id) -> Signal<ExteralessTLValue, NoError> {
    return account.postbox.transaction { transaction -> ExteralessTLValue in
        guard let message = transaction.getMessage(messageId) else { return .null }
        let files = message.effectiveMedia.compactMap { $0 as? TelegramMediaFile }
        return .object(["files": .array(files.prefix(64).map(nativeServiceFileValue)), "total": .integer(Int64(files.count)),
            "exportAllowed": .bool(!message.isCopyProtected() && message.secretMediaDuration == nil)])
    }
}

/// Cache status uses asynchronous MediaBox APIs. approximateSynchronousValue and
/// attemptSynchronously are deliberately left false: no main/Postbox queue wait.
public func nativeServiceResourceStatus(account: Account, messageId: EngineMessage.Id, fileId: Int64) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    return nativeServiceMessageFile(account: account, messageId: messageId, fileId: fileId)
    |> mapToSignal { _, file -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        return account.postbox.mediaBox.resourceStatus(file.resource)
        |> map { status -> ExteralessTLValue in
            var value: [String: ExteralessTLValue] = ["file": nativeServiceFileValue(file)]
            switch status {
            case .Local:
                value["status"] = .string("local")
                value["progress"] = .double(1.0)
            case let .Remote(progress):
                value["status"] = .string("remote")
                value["progress"] = .double(Double(progress))
            case let .Fetching(isActive, progress):
                value["status"] = .string("fetching")
                value["active"] = .bool(isActive)
                value["progress"] = .double(Double(progress))
            case let .Paused(progress):
                value["status"] = .string("paused")
                value["progress"] = .double(Double(progress))
            }
            return .object(value)
        }
        |> castError(ExteralessTLServiceError.self)
    }
}

/// Owns one native fetch reference. Disposing cancels THIS subscriber, respecting
/// MediaBox refcounts if Telegram or another plugin still needs the same resource.
/// Success is emitted only when MediaBox says a real complete local file exists.
public func nativeServiceDownload(account: Account, messageId: EngineMessage.Id, fileId: Int64,
                                  isCancelled: @escaping () -> Bool) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    return nativeServiceMessageFile(account: account, messageId: messageId, fileId: fileId)
    |> mapToSignal { message, file -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        guard !isCancelled() else { return .fail(.local("MEDIA_FETCH_CANCELLED")) }
        return Signal { subscriber in
            guard !isCancelled() else {
                subscriber.putError(.local("MEDIA_FETCH_CANCELLED"))
                return EmptyDisposable
            }
            let disposables = DisposableSet()
            disposables.add((account.postbox.mediaBox.resourceData(file.resource)
            |> filter { $0.complete }
            |> take(1)).start(next: { data in
                subscriber.putNext(.object(["file": nativeServiceFileValue(file), "path": .string(data.path), "size": .integer(data.size)]))
                subscriber.putCompletion()
            }))
            let reference = FileMediaReference.message(message: MessageReference(message), media: file)
            disposables.add(fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(messageId.peerId),
                userContentType: .file, reference: reference.resourceReference(file.resource), reportResultStatus: true).start(error: { _ in
                    subscriber.putError(.local("MEDIA_FETCH_FAILED"))
                }))
            return disposables
        }
    }
}

/// File-opening hook helper. A missing/incomplete resource returns nil and leaves
/// the original native preview/download flow in charge; it never starts a fetch.
public func nativeServiceLocalFile(account: Account, file: TelegramMediaFile) -> Signal<String?, NoError> {
    return account.postbox.mediaBox.resourceData(file.resource)
    |> take(1)
    |> map { data -> String? in data.complete ? data.path : nil }
}
