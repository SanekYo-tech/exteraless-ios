import Foundation
import MtProtoKit
import PluginHooks
import SwiftSignalKit
internal import TelegramApi

private func tlRequestTransformsEnabled() -> Bool {
    return (PluginHookRouter.hasSubscribers(.preRequest) && PluginTLTransformRouter.hasSubscribers(.preRequest))
        || (PluginHookRouter.hasSubscribers(.postRequest) && PluginTLTransformRouter.hasSubscribers(.postRequest))
}

/// Insert as the first branch in Network.request, before its privacy willSubmit.
/// nil preserves the stock empty-gate path; this path owns BOTH request hook phases.
func exteralessTransformedRequest<T>(network: Network, data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
                                    tag: NetworkRequestDependencyTag?, automaticFloodWait: Bool,
                                    onFloodWaitError: ((String) -> Void)?) -> Signal<T, MTRpcError>? {
    guard let events = tlTransformedRequestEvents(network: network, data: data, info: [], usesAdditionalInfo: false, tag: tag,
        automaticFloodWait: automaticFloodWait, onFloodWaitError: onFloodWaitError) else { return nil }
    return events
    |> mapToSignal { event -> Signal<T, MTRpcError> in
        if case let .result(value) = event { return .single(value) }
        return .complete()
    }
}

func exteralessTransformedRequestWithAdditionalInfo<T>(network: Network, data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
                                                       info: NetworkRequestAdditionalInfo, tag: NetworkRequestDependencyTag?,
                                                       automaticFloodWait: Bool, onFloodWaitError: ((String) -> Void)?) -> Signal<NetworkRequestResult<T>, MTRpcError>? {
    return tlTransformedRequestEvents(network: network, data: data, info: info, usesAdditionalInfo: true, tag: tag,
        automaticFloodWait: automaticFloodWait, onFloodWaitError: onFloodWaitError)
}

private func tlTransformedRequestEvents<T>(network: Network, data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
                                         info: NetworkRequestAdditionalInfo, usesAdditionalInfo: Bool, tag: NetworkRequestDependencyTag?,
                                         automaticFloodWait: Bool, onFloodWaitError: ((String) -> Void)?) -> Signal<NetworkRequestResult<T>, MTRpcError>? {
    let permitsPluginEvents = !exteralessClientAPIRequestContainsIdentity(data.0) && tlRequestTransformsEnabled()
    let submission: PluginTLSubmissionOrder.Ticket
    switch PluginTLSubmissionOrder.shared.reserveIfNeeded(accountRecordId: network.accountRecordId, transformsEnabled: permitsPluginEvents) {
    case .bypass: return nil
    case .full:
        let error: MTRpcError = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_TL_PREFIX_QUEUE_FULL")
        return .fail(error)
    case let .reserved(ticket): submission = ticket
    }
    let service = network.requestService
    return Signal { [weak network, service] subscriber in
        guard let network else {
            PluginTLSubmissionOrder.shared.cancel(submission)
            let error: MTRpcError = MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")
            subscriber.putError(error)
            return EmptyDisposable
        }
        let operation = TLNetworkRequestOperation(network: network, service: service, data: data, info: info, usesAdditionalInfo: usesAdditionalInfo,
            tag: tag, automaticFloodWait: automaticFloodWait, onFloodWaitError: onFloodWaitError,
            submission: submission, permitsPluginEvents: permitsPluginEvents,
            next: { subscriber.putNext($0) }, failed: { subscriber.putError($0) }, completed: { subscriber.putCompletion() })
        operation.start()
        return ActionDisposable { operation.cancel() }
    }
}

private final class TLNetworkParsedResponse<T>: BoxedMessage {
    let value: T
    let bytes: Data
    init(value: T, bytes: Data) {
        self.value = value
        self.bytes = bytes
        super.init(value)
    }
}

private final class TLNetworkSubmissionReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func markCompleted() { self.lock.lock(); self.completed = true; self.lock.unlock() }
    var hasCompleted: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.completed }
}

private final class TLNetworkRequestOperation<T>: @unchecked Sendable {
    private weak var network: Network?
    private let service: NetworkEngineRequestService
    private let data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>)
    private let info: NetworkRequestAdditionalInfo
    private let tag: NetworkRequestDependencyTag?
    private let automaticFloodWait: Bool
    private let onFloodWaitError: ((String) -> Void)?
    private let next: (NetworkRequestResult<T>) -> Void
    private let failed: (MTRpcError) -> Void
    private let completed: () -> Void
    private let gate = PluginTLSubmissionGate()
    private let queue = DispatchQueue(label: "Exteraless.TLRPC", qos: .userInitiated)
    private let metadata: PluginRequestMetadata
    private let baseMetadataValue: ExteralessTLValue
    private var origin: ExteralessTLRequestOrigin?
    private var originCorrelations: [Int64] = []
    private var metadataValue: ExteralessTLValue {
        guard let origin, case var .object(fields) = self.baseMetadataValue else { return self.baseMetadataValue }
        fields["origin"] = .object(["rootId": .string(origin.rootId), "pluginIds": .array(origin.pluginIds.map(ExteralessTLValue.string))])
        return .object(fields)
    }
    private let transformPre: Bool
    private let transformPost: Bool
    private let permitsPluginEvents: Bool
    private let submission: PluginTLSubmissionOrder.Ticket
    private let prefixDeadline: UInt64
    private var prefixTimer: DispatchSourceTimer?
    private var requestModel: ExteralessTLRequest?
    private var didReceiveTerminal = false // queue-only, protects synchronous/duplicate engines

    init(network: Network, service: NetworkEngineRequestService, data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
         info: NetworkRequestAdditionalInfo, usesAdditionalInfo: Bool, tag: NetworkRequestDependencyTag?, automaticFloodWait: Bool,
         onFloodWaitError: ((String) -> Void)?, submission: PluginTLSubmissionOrder.Ticket, permitsPluginEvents: Bool,
         next: @escaping (NetworkRequestResult<T>) -> Void,
         failed: @escaping (MTRpcError) -> Void, completed: @escaping () -> Void) {
        self.network = network
        self.service = service
        self.data = data
        self.info = info
        self.tag = tag
        self.automaticFloodWait = automaticFloodWait
        self.onFloodWaitError = onFloodWaitError
        self.next = next
        self.failed = failed
        self.completed = completed
        self.submission = submission
        self.prefixDeadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
        let id = UUID().uuidString
        self.metadata = PluginRequestMetadata(accountRecordId: network.accountRecordId, requestId: id,
            requestName: data.0.name, datacenterId: network.datacenterId, automaticFloodWait: automaticFloodWait,
            usesAdditionalInfo: usesAdditionalInfo)
        self.baseMetadataValue = .object(["accountRecordId": .integer(network.accountRecordId), "requestId": .string(id),
            "requestName": .string(data.0.name), "datacenterId": .integer(Int64(network.datacenterId)),
            "automaticFloodWait": .bool(automaticFloodWait), "usesAdditionalInfo": .bool(usesAdditionalInfo)])
        self.permitsPluginEvents = permitsPluginEvents
        self.transformPre = permitsPluginEvents && PluginHookRouter.hasSubscribers(.preRequest) && PluginTLTransformRouter.hasSubscribers(.preRequest)
        self.transformPost = permitsPluginEvents && PluginHookRouter.hasSubscribers(.postRequest) && PluginTLTransformRouter.hasSubscribers(.postRequest)
        self.gate.bind { PluginTLSubmissionOrder.shared.cancel(submission) }
    }

    func start() {
        self.queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: self.prefixDeadline))
            timer.setEventHandler { [weak self] in
                guard let self, !self.gate.hasSubmitted else { return }
                self.fail("EXTERALESS_TL_PREFIX_TIMEOUT")
            }
            self.prefixTimer = timer
            timer.resume()
            self.gate.bind { timer.cancel() }
            PluginTLSubmissionOrder.shared.begin(self.submission) { [weak self] in
                guard let self else { return }
                self.queue.async { self.prepare() }
            }
        }
    }

    func cancel() { self.gate.stop() }

    private func fail(_ error: MTRpcError) {
        if self.gate.stop() { self.failed(error) }
    }

    private func fail(_ text: String) {
        let error: MTRpcError = MTRpcError(errorCode: -1, errorDescription: text)
        self.fail(error)
    }

    private func payload(kind: PluginTLTransformKind, value: ExteralessTLValue, error: MTRpcError? = nil,
                         canCancel: Bool = true, metadata: ExteralessTLValue? = nil,
                         normalize: @escaping @Sendable (String) throws -> String) throws -> PluginTLTransformPayload {
        return PluginTLTransformPayload(kind: kind, accountRecordId: self.metadata.accountRecordId,
            correlationId: self.metadata.requestId, name: self.metadata.requestName, valueJSON: try value.jsonString(),
            metadataJSON: try (metadata ?? self.metadataValue).jsonString(), error: error.map { PluginRPCError(code: $0.errorCode, message: $0.errorDescription ?? "") },
            canCancel: canCancel, originPluginIds: self.origin?.pluginIds ?? [], originRootId: self.origin?.rootId, normalize: normalize)
    }

    private func postMetadata(_ info: NetworkEngineResponseInfo) -> ExteralessTLValue {
        guard case var .object(fields) = self.metadataValue else { return self.metadataValue }
        fields["response"] = .object(["timestamp": .double(info.timestamp), "duration": .double(info.duration),
            "networkType": .integer(Int64(info.networkType))])
        return .object(fields)
    }

    private func prepare() {
        guard self.gate.isActive, let network = self.network, exteralessTLAccountIsCurrent(network) else {
            self.fail("ACCOUNT_CONTEXT_RELEASED")
            return
        }
        let codec = ExteralessTLCodec.shared
        let body = self.data.1.makeData()
        if exteralessClientAPIRequestContainsIdentity(self.data.0) {
            // C5 private identity requests may queue behind A but never reach a
            // plugin decoder, transformer or observational payload.
            self.submit(description: self.data.0, body: body, observePre: false, allowPostTransform: false)
            return
        }
        do {
            let value = try codec.decodeRequest(body)
            let request = try codec.encodeRequest(value)
            guard request.methodName == self.data.0.name else { self.fail("EXTERALESS_TL_DESCRIPTOR_MISMATCH"); return }
            self.requestModel = request
            let disposable = exteralessTLResolveRequestOrigin(network: network, description: self.data.0, value: value, tag: self.tag).start(next: { [weak self] resolved in
                guard let self else { return }
                self.queue.async {
                    guard self.gate.isActive else { return }
                    self.origin = resolved.origin
                    self.originCorrelations = resolved.correlations
                    self.interceptPre(request: request, value: value, body: body)
                }
            }, error: { [weak self] error in
                guard let self else { return }
                self.queue.async { self.fail(error) }
            })
            self.gate.bind { disposable.dispose() }
        } catch {
            // Native-only/generic TL without a portable schema keeps the original
            // parser and observation path. It is never represented by fake params.
            self.submit(description: self.data.0, body: body, observePre: true, allowPostTransform: false)
        }
    }

    private func interceptPre(request: ExteralessTLRequest, value: ExteralessTLValue, body: Data) {
        guard self.gate.isActive else { return }
        let codec = ExteralessTLCodec.shared
        do {
            guard self.transformPre else { self.prepareDescriptor(request, originalBody: body, observed: true); return }
            let metadata = self.metadataValue
            let payload = try self.payload(kind: .preRequest, value: value, normalize: { source in
                let candidate = try ExteralessTLTransformCodec.request(source, original: request, metadata: metadata)
                return try codec.decodeRequest(candidate.body).jsonString()
            })
            let cancellation = PluginTLTransformRouter.intercept(payload) { [weak self] decision in
                guard let self else { return }
                self.queue.async {
                    guard self.gate.isActive else { return }
                    switch decision {
                    case .cancel: self.fail("EXTERALESS_PRE_REQUEST_CANCELLED")
                    case let .failure(reason): self.fail("EXTERALESS_" + reason)
                    case .keepOriginal: self.prepareDescriptor(request, originalBody: body, observed: false)
                    case let .modify(json), let .modifyFinal(json):
                        do {
                            let candidate = try ExteralessTLTransformCodec.request(json, original: request, metadata: metadata)
                            self.requestModel = candidate
                            self.prepareDescriptor(candidate, originalBody: body, observed: false)
                        } catch {
                            PluginTLTransformRouter.report("TL_HOOK_INVALID_REPLACEMENT", payload: payload)
                            self.prepareDescriptor(request, originalBody: body, observed: false)
                        }
                    }
                }
            }
            if let cancellation { self.gate.bind { cancellation.cancel() } }
        } catch {
            self.fail("EXTERALESS_TL_HOOK_PAYLOAD_INVALID")
        }
    }

    private func prepareDescriptor(_ request: ExteralessTLRequest, originalBody: Data, observed: Bool) {
        guard self.gate.isActive, let network = self.network else { self.fail("ACCOUNT_CONTEXT_RELEASED"); return }
        let original = request.body == originalBody ? self.data.0 : nil
        let disposable = exteralessTLPrepareDescriptor(network: network, request: request, preserving: original).start(next: { [weak self] description in
            guard let self else { return }
            self.queue.async {
                if let network = self.network { exteralessTLBindRequestOrigin(self.origin, network: network, description: description) }
                self.submit(description: description, body: request.body, observePre: observed, allowPostTransform: true)
            }
        }, error: { [weak self] error in
            self?.queue.async { self?.fail(error) }
        })
        self.gate.bind { disposable.dispose() }
    }

    private func submit(description: FunctionDescription, body: Data, observePre: Bool, allowPostTransform: Bool) {
        guard self.gate.isActive else { return }
        PluginTLSubmissionOrder.shared.ready(self.submission) { [weak self] in
            self?.commitSubmission(description: description, body: body, observePre: observePre, allowPostTransform: allowPostTransform)
        }
    }

    private func commitSubmission(description: FunctionDescription, body: Data, observePre: Bool, allowPostTransform: Bool) {
        var refused: MTRpcError?
        self.gate.submit {
            guard DispatchTime.now().uptimeNanoseconds < self.prefixDeadline else {
                refused = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_TL_PREFIX_TIMEOUT")
                return nil
            }
            self.prefixTimer?.cancel()
            guard let network = self.network, exteralessTLAccountIsCurrent(network) else {
                refused = MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")
                return nil
            }
            // FINAL params, after the async prefix and immediately before admission.
            guard exteralessTLCanExecuteRequest(network: network, description: self.data.0),
                  exteralessTLCanExecuteRequest(network: network, description: description) else {
                refused = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_EXECUTION_REVOKED")
                return nil
            }
            if let error = exteralessPrivacyRequestError(network: network, description: description, body: body) {
                refused = error
                return nil
            }
            if self.permitsPluginEvents, observePre, PluginHookRouter.hasSubscribers(.preRequest) {
                let metadata = self.metadata
                PluginHookRouter.observe(.preRequest) { .preRequest(PluginRequestObservation(phase: .beforeSubmission,
                    metadata: metadata, serializedTLBytes: body, tlBytesEncoding: .requestBody)) }
            }
            let parser = self.data.2
            let acknowledged: (() -> Void)?
            if self.info.contains(.acknowledgement) {
                acknowledged = { [weak self] in
                    guard let self else { return }
                    self.queue.async { if self.gate.isActive && !self.didReceiveTerminal { self.next(.acknowledged) } }
                }
            } else { acknowledged = nil }
            let progress: ((Float, Int) -> Void)?
            if self.info.contains(.progress) {
                progress = { [weak self] progress, packetSize in
                    guard let self else { return }
                    self.queue.async { if self.gate.isActive && !self.didReceiveTerminal { self.next(.progress(progress, Int32(clamping: packetSize))) } }
                }
            } else { progress = nil }
            let receipt = TLNetworkSubmissionReceipt()
            let request = NetworkEngineRequest(payload: body,
                metadata: WrappedRequestMetadata(metadata: exteralessClientAPIRequestLogMetadata(description), tag: self.tag),
                shortMetadata: WrappedRequestShortMetadata(shortMetadata: WrappedShortFunctionDescription(description)),
                logContext: MTRequestLogContext.context(payload: body, methodName: description.name)
                    .merging(.context(payload: self.data.1.makeData(), methodName: self.data.0.name)),
                parse: { bytes in
                    // Preserve engine TL_PARSING_ERROR / apiInitializationHash reset
                    // semantics. A replacement is parsed AGAIN after its post hook.
                    guard let value = parser.parse(Buffer(data: bytes)) else { return nil }
                    return TLNetworkParsedResponse(value: value, bytes: bytes)
                }, options: NetworkEngineRequestOptions(),
                shouldContinueAfterError: networkRequestErrorPolicy(automaticFloodWait: self.automaticFloodWait,
                    onFloodWaitError: self.onFloodWaitError, failOnServerErrors: false),
                dependsOn: networkRequestDependency(tag: self.tag),
                 acknowledged: acknowledged, progress: progress, completed: { [weak self] result in
                    receipt.markCompleted()
                    guard let self else { return }
                    self.queue.async { self.received(result, description: description, allowPostTransform: allowPostTransform) }
                })
            let disposable = self.service.add(request)
            if disposable === EmptyDisposable {
                // A synchronous fake/native terminal may legitimately need no
                // disposable. Its exact response/error still owns termination.
                if !receipt.hasCompleted { refused = MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED") }
            } else {
                // CANCEL/dispose-before-submit/refused add cannot mark a chat read.
                exteralessPrivacyWillSubmit(network: network, description: description)
            }
            return { disposable.dispose() }
        }
        if let refused { self.fail(refused) }
    }

    private func received(_ result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>, description: FunctionDescription, allowPostTransform: Bool) {
        guard self.gate.isActive, !self.didReceiveTerminal else { return }
        self.didReceiveTerminal = true
        if let network = self.network { exteralessPrivacyDidComplete(network: network, description: description) }
        switch result {
        case let .success(response):
            if let network = self.network, !self.originCorrelations.isEmpty {
                exteralessTLReleaseEnqueueOrigin(network: network, correlations: self.originCorrelations)
            }
            guard let parsed = response.result as? TLNetworkParsedResponse<T> else {
                let error: MTRpcError = MTRpcError(errorCode: 500, errorDescription: "TL_VERIFICATION_ERROR")
                self.fail(error); return
            }
            if allowPostTransform && self.transformPost, let request = self.requestModel {
                self.post(parsed, request: request, info: response.info)
            } else {
                self.observePost(bytes: parsed.bytes, info: response.info, error: nil)
                self.succeed(parsed.value)
            }
        case let .failure(failure):
            if allowPostTransform && self.transformPost { self.postError(failure) }
            else {
                self.observePost(bytes: nil, info: failure.info, error: failure.error)
                self.fail(failure.error)
            }
        }
    }

    private func post(_ parsed: TLNetworkParsedResponse<T>, request: ExteralessTLRequest, info: NetworkEngineResponseInfo) {
        let codec = ExteralessTLCodec.shared
        do {
            let value = try codec.decode(parsed.bytes, as: request.resultType)
            let metadata = self.postMetadata(info)
            let payload = try self.payload(kind: .postRequest, value: value, canCancel: ExteralessTLTransformCodec.canCancelResponse(value), metadata: metadata, normalize: { json in
                let body = try ExteralessTLTransformCodec.response(json, original: value, type: request.resultType, metadata: metadata)
                return try codec.decode(body, as: request.resultType).jsonString()
            })
            let cancellation = PluginTLTransformRouter.intercept(payload) { [weak self] decision in
                guard let self else { return }
                self.queue.async {
                    guard self.gate.isActive else { return }
                    switch decision {
                    case .cancel: self.fail("EXTERALESS_POST_REQUEST_CANCELLED")
                    case let .modify(json), let .modifyFinal(json):
                        do {
                            let bytes = try ExteralessTLTransformCodec.response(json, original: value, type: request.resultType, metadata: metadata)
                            guard let replacement = self.data.2.parse(Buffer(data: bytes)) else { throw ExteralessTLError(.schema, "Original native response parser rejected replacement") }
                            self.succeed(replacement)
                        } catch {
                            PluginTLTransformRouter.report("TL_HOOK_NATIVE_PARSER_REJECTED", payload: payload)
                            self.succeed(parsed.value)
                        }
                    case .failure:
                        PluginTLTransformRouter.report("TL_POST_HOOK_FALLBACK", payload: payload)
                        self.succeed(parsed.value)
                    case .keepOriginal: self.succeed(parsed.value)
                    }
                }
            }
            if let cancellation { self.gate.bind { cancellation.cancel() } }
        } catch {
            // A nonportable response still has its genuine, successfully parsed T.
            self.observePost(bytes: parsed.bytes, info: info, error: nil)
            self.succeed(parsed.value)
        }
    }

    private func postError(_ failure: NetworkEngineRequestFailure) {
        do {
            let payload = try self.payload(kind: .postRequest, value: .null, error: failure.error, metadata: self.postMetadata(failure.info), normalize: { _ in
                throw ExteralessTLError(.malformed, "RPC errors are read-only; cannot fabricate a successful T")
            })
            let cancellation = PluginTLTransformRouter.intercept(payload) { [weak self] decision in
                guard let self else { return }
                self.queue.async {
                    if decision == .cancel { self.fail("EXTERALESS_POST_REQUEST_CANCELLED") }
                    else { self.fail(failure.error) }
                }
            }
            if let cancellation { self.gate.bind { cancellation.cancel() } }
        } catch { self.fail(failure.error) }
    }

    private func observePost(bytes: Data?, info: NetworkEngineResponseInfo, error: MTRpcError?) {
        guard self.permitsPluginEvents, PluginHookRouter.hasSubscribers(.postRequest) else { return }
        let metadata = self.metadata
        PluginHookRouter.observe(.postRequest) { .postRequest(PluginRequestObservation(phase: .completed,
            metadata: metadata, serializedTLBytes: bytes, tlBytesEncoding: bytes == nil ? .unavailable : .responseBody,
            response: PluginRPCResponseMetadata(timestamp: info.timestamp, duration: info.duration, networkType: info.networkType),
            error: error.map { PluginRPCError(code: $0.errorCode, message: $0.errorDescription ?? "") })) }
    }

    private func succeed(_ value: T) {
        guard self.gate.stop() else { return }
        self.next(.result(value))
        self.completed()
    }
}
