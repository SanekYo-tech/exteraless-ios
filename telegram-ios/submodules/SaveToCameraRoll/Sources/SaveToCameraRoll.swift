import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Photos
import Display
import UniformTypeIdentifiers
import DeviceAccess
import AccountContext
import LegacyComponents

public enum FetchMediaDataState {
    case progress(Float)
    case data(EngineMediaResource.ResourceData)
}

public func fetchMediaData(context: AccountContext, userLocation: MediaResourceUserLocation, customUserContentType: MediaResourceUserContentType? = nil, mediaReference: AnyMediaReference, forceVideo: Bool = false, onFailure: (() -> Void)? = nil) -> Signal<(FetchMediaDataState, Bool), NoError> {
    var resource: TelegramMediaResource?
    var isImage = true
    var fileExtension: String?
    var userContentType: MediaResourceUserContentType = .other
    if let image = mediaReference.media as? TelegramMediaImage {
        userContentType = .image
        if let video = image.videoRepresentations.last, forceVideo {
            resource = video.resource
            isImage = false
        } else if let representation = largestImageRepresentation(image.representations) {
            resource = representation.resource
        }
    } else if let file = mediaReference.media as? TelegramMediaFile {
        userContentType = MediaResourceUserContentType(file: file)
        resource = file.resource
        if file.isVideo || file.mimeType.hasPrefix("video/") {
            isImage = false
        }
        let maybeExtension = ((file.fileName ?? "") as NSString).pathExtension
        if !maybeExtension.isEmpty {
            fileExtension = maybeExtension
        }
    } else if let webpage = mediaReference.media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
        if let file = content.file {
            resource = file.resource
            if file.isVideo {
                isImage = false
            }
        } else if let image = content.image {
            if let representation = largestImageRepresentation(image.representations) {
                resource = representation.resource
            }
        }
    }
    if let customUserContentType {
        userContentType = customUserContentType
    }

    if let resource = resource {
        let engineResource = EngineMediaResource(resource)
        let fetchedData: Signal<FetchMediaDataState, NoError> = Signal { subscriber in
            let disposed = Atomic(value: false)
            let fetched = context.engine.resources.fetch(
                reference: mediaReference.resourceReference(resource),
                userLocation: userLocation,
                userContentType: userContentType
            ).start(error: { _ in
                if !disposed.with({ $0 }), let onFailure { onFailure(); subscriber.putCompletion() }
            })
            let status = context.engine.resources.status(resource: engineResource).start(next: { status in
                switch status {
                    case .Local:
                        subscriber.putNext(.progress(1.0))
                    case .Remote:
                        subscriber.putNext(.progress(0.0))
                    case let .Fetching(_, progress):
                        subscriber.putNext(.progress(progress))
                    case let .Paused(progress):
                        subscriber.putNext(.progress(progress))
                }
            })
            let data = context.engine.resources.data(
                resource: engineResource,
                pathExtension: fileExtension,
                waitUntilFetchStatus: true
            ).start(next: { next in
                subscriber.putNext(.data(next))
            }, completed: {
                subscriber.putCompletion()
            })
            return ActionDisposable {
                _ = disposed.swap(true)
                fetched.dispose()
                status.dispose()
                data.dispose()
            }
        }
        return fetchedData
        |> map { data in
            return (data, isImage)
        }
    } else {
        return .complete()
    }
}

struct ExteralessCameraRollData {
    let main: EngineMediaResource.ResourceData
    let video: EngineMediaResource.ResourceData?
    let isImage: Bool
}

enum ExteralessCameraRollInput {
    case progress(Float)
    case ready(ExteralessCameraRollData)
}

final class ExteralessCameraRollPrepared {
    enum Content {
        case image(Data)
        case video(URL)
        case livePhoto(Data, URL)
    }
    let content: Content
    private let cleanup: Disposable

    init(content: Content, cleanup: Disposable = EmptyDisposable) {
        self.content = content
        self.cleanup = cleanup
    }

    func dispose() { self.cleanup.dispose() }
}

/// These are the actual native I/O boundaries, also injectable without Account/Photos in tests.
struct ExteralessCameraRollSinks {
    let authorize: (@escaping (Bool) -> Void) -> Disposable
    let prepare: (ExteralessCameraRollData, @escaping (ExteralessCameraRollPrepared?) -> Void) -> Disposable
    let save: (ExteralessCameraRollPrepared, @escaping (() -> Void) -> Bool, @escaping (Bool) -> Void) -> Disposable
}

private final class ExteralessCameraRollOperation {
    private enum Phase { case loading, authorizing, preparing, awaitingCommit, committed, finished }
    private let lock = NSLock()
    private var phase = Phase.loading
    private var subscriber: Subscriber<Float, NoError>?
    private var prepared: ExteralessCameraRollPrepared?
    private let permit: ExteralessContentExportPermit
    private let accountId: Int64
    private let owner: AnyObject?
    private let current: () -> Bool
    private let sinks: ExteralessCameraRollSinks
    private let input = MetaDisposable()
    private let authorization = MetaDisposable()
    private let preparation = MetaDisposable()
    private let saving = MetaDisposable()
    private let revocation = MetaDisposable()
    private let validity = MetaDisposable()

    init(permit: ExteralessContentExportPermit, accountId: Int64, owner: AnyObject?, current: @escaping () -> Bool, sinks: ExteralessCameraRollSinks, subscriber: Subscriber<Float, NoError>) {
        self.permit = permit
        self.accountId = accountId
        self.owner = owner
        self.current = current
        self.sinks = sinks
        self.subscriber = subscriber
    }

    private func move(from: Phase, to: Phase) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.phase == from else { return false }
        self.phase = to
        return true
    }

    private func isPhase(_ phase: Phase) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.phase == phase
    }

    func start(_ input: Signal<ExteralessCameraRollInput, NoError>, validity: Signal<Bool, NoError>?) {
        self.revocation.set(self.permit.onRevocation { [weak self] in self?.finish(success: false) })
        self.validity.set(((validity ?? .single(true)) |> deliverOnMainQueue).start(next: { [weak self] valid in
            if !valid { self?.finish(success: false) }
        }))
        guard self.current(), self.permit.allows(accountId: self.accountId, operation: .exportPreparation) else { self.finish(success: false); return }
        self.input.set((input |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            guard self.current(), self.permit.allows(accountId: self.accountId, operation: .exportPreparation) else { self.finish(success: false); return }
            switch value {
            case let .progress(progress):
                self.lock.lock()
                let subscriber = self.phase == .loading ? self.subscriber : nil
                self.lock.unlock()
                if progress.isFinite { subscriber?.putNext(max(0, min(0.99, progress))) }
            case let .ready(data):
                guard self.move(from: .loading, to: .authorizing) else { return }
                self.input.dispose()
                self.authorization.set(self.sinks.authorize { [weak self] allowed in
                    Queue.mainQueue().async {
                        guard let self else { return }
                        guard self.isPhase(.authorizing) else { return }
                        guard allowed, self.current(), self.permit.allows(accountId: self.accountId, operation: .exportPreparation) else { self.finish(success: false); return }
                        guard self.move(from: .authorizing, to: .preparing) else { return }
                        self.preparation.set(self.sinks.prepare(data, { [weak self] prepared in
                            Queue.mainQueue().async {
                                guard let self else { prepared?.dispose(); return }
                                self.accept(prepared)
                            }
                        }))
                    }
                })
            }
        }, completed: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let missing = self.phase == .loading
            self.lock.unlock()
            if missing { self.finish(success: false) }
        }))
    }

    private func accept(_ value: ExteralessCameraRollPrepared?) {
        guard self.isPhase(.preparing) else { value?.dispose(); return }
        guard let value, self.current(), self.permit.allows(accountId: self.accountId, operation: .exportPreparation) else {
            value?.dispose(); self.finish(success: false); return
        }
        self.lock.lock()
        guard self.phase == .preparing else { self.lock.unlock(); value.dispose(); return }
        self.prepared = value
        self.phase = .awaitingCommit
        self.lock.unlock()
        // The Photos change block is a later callback. It must claim the same permit AGAIN.
        self.saving.set(self.sinks.save(value, { [weak self] effect in
            guard let self else { return false }
            return self.permit.perform(accountId: self.accountId, operation: .exportEffect, current: {
                self.current() && self.move(from: .awaitingCommit, to: .committed)
            }, effect)
        }, { [weak self] success in
            Queue.mainQueue().async { self?.finish(success: success) }
        }))
    }

    func finish(success: Bool) {
        self.lock.lock()
        guard self.phase != .finished else { self.lock.unlock(); return }
        let succeeded = success && self.phase == .committed
        self.phase = .finished
        let subscriber = self.subscriber
        let prepared = self.prepared
        self.subscriber = nil
        self.prepared = nil
        self.lock.unlock()
        self.input.dispose()
        self.authorization.dispose()
        self.preparation.dispose()
        self.saving.dispose()
        self.revocation.dispose()
        self.validity.dispose()
        prepared?.dispose()
        if !succeeded { self.permit.revoke() }
        Queue.mainQueue().async { [permit = self.permit, accountId = self.accountId, owner = self.owner, current = self.current] in
            withExtendedLifetime(owner) {
                if succeeded && current() && permit.allows(accountId: accountId) { subscriber?.putNext(1.0) }
                subscriber?.putCompletion()
            }
        }
    }
}

func exteralessCameraRollSave(input: Signal<ExteralessCameraRollInput, NoError>, permit: ExteralessContentExportPermit, accountId: Int64, owner: AnyObject? = nil, current: @escaping () -> Bool = { true }, validity: Signal<Bool, NoError>? = nil, sinks: ExteralessCameraRollSinks) -> Signal<Float, NoError> {
    return Signal { subscriber in
        let operation = ExteralessCameraRollOperation(permit: permit, accountId: accountId, owner: owner, current: current, sinks: sinks, subscriber: subscriber)
        operation.start(input, validity: validity)
        return ActionDisposable { operation.finish(success: false) }
    }
}

private func exteralessCameraRollPrepare(_ data: ExteralessCameraRollData, permit: ExteralessContentExportPermit, accountId: Int64, current: @escaping () -> Bool, completion: @escaping (ExteralessCameraRollPrepared?) -> Void) -> Disposable {
    let cancelled = Atomic(value: false)
    let export = MetaDisposable()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("exteraless-export-\(UUID().uuidString)", isDirectory: true)
    let cleanupNow = { let _ = try? FileManager.default.removeItem(at: directory) }
    let cleanup = ActionDisposable(action: cleanupNow)
    Queue.concurrentDefaultQueue().async {
        var prepared: ExteralessCameraRollPrepared?
        var asynchronous = false
        let admitted = permit.perform(accountId: accountId, operation: .exportPreparation, current: { current() && !cancelled.with { $0 } }) {
            if data.isImage {
                guard let image = try? Data(contentsOf: URL(fileURLWithPath: data.main.path)) else { return }
                if let video = data.video {
                    let identifier = UUID().uuidString
                    guard let jpeg = addAssetIdentifierToJPEG(image, assetIdentifier: identifier) else { return }
                    let input = directory.appendingPathComponent("input.mp4")
                    let output = directory.appendingPathComponent("paired.mov")
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: video.path), to: input)
                    } catch { return }
                    guard !cancelled.with({ $0 }) else { return }
                    asynchronous = true
                    export.set(addAssetIdentifierToVideo(inputURL: input, outputURL: output, assetIdentifier: identifier, completion: { success in
                        if success, current(), !cancelled.with({ $0 }), permit.allows(accountId: accountId, operation: .exportPreparation) {
                            completion(ExteralessCameraRollPrepared(content: .livePhoto(jpeg, output), cleanup: cleanup))
                        } else {
                            cleanupNow()
                            completion(nil)
                        }
                    }))
                } else {
                    prepared = ExteralessCameraRollPrepared(content: .image(image))
                }
            } else {
                let output = directory.appendingPathComponent("video.mp4")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: data.main.path), to: output)
                    prepared = ExteralessCameraRollPrepared(content: .video(output), cleanup: cleanup)
                } catch { return }
            }
        }
        if !admitted || cancelled.with({ $0 }) {
            cleanupNow()
            if !asynchronous { completion(nil) }
        } else if !asynchronous {
            if prepared == nil { cleanupNow() }
            completion(prepared)
        }
    }
    return ActionDisposable {
        _ = cancelled.swap(true)
        export.dispose()
        cleanup.dispose()
    }
}

private func exteralessCameraRollNativeSinks(context: AccountContext, permit: ExteralessContentExportPermit, current: @escaping () -> Bool, present: ((ViewController, Any?) -> Void)?) -> ExteralessCameraRollSinks {
    let accountId = context.account.id.int64
    return ExteralessCameraRollSinks(authorize: { completion in
        guard current(), permit.allows(accountId: accountId, operation: .exportPreparation) else { completion(false); return EmptyDisposable }
        DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { controller, arguments in
            guard current(), permit.allows(accountId: accountId, operation: .presentation) else { return }
            present?(controller, arguments)
        }, openSettings: {
            permit.perform(accountId: accountId, operation: .exportPreparation, current: current) { context.sharedContext.applicationBindings.openSettings() }
        }, completion)
        return EmptyDisposable // The system permission callback is rechecked even after disposal.
    }, prepare: { data, completion in
        exteralessCameraRollPrepare(data, permit: permit, accountId: accountId, current: current, completion: completion)
    }, save: { prepared, commit, completion in
        guard current(), permit.allows(accountId: accountId) else { completion(false); return EmptyDisposable }
        let committed = Atomic(value: false)
        PHPhotoLibrary.shared().performChanges({
            var created = false
            let admitted = commit {
                switch prepared.content {
                case let .image(data):
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    created = true
                case let .video(url):
                    created = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) != nil
                case let .livePhoto(data, url):
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: url, options: nil)
                    created = true
                }
            }
            _ = committed.swap(admitted && created)
        }, completionHandler: { success, _ in
            completion(success && committed.with { $0 })
        })
        return EmptyDisposable // A claimed Photos transaction cannot be recalled; no late success is published.
    })
}

public func saveToCameraRoll(context: AccountContext, userLocation: MediaResourceUserLocation, customUserContentType: MediaResourceUserContentType? = nil, mediaReference: AnyMediaReference, video: AnyMediaReference? = nil, exportPermit: ExteralessContentExportPermit? = nil, exportReference: ExteralessContentExportPermitReference? = nil, exportCurrent: (() -> Bool)? = nil, exportValidity: Signal<Bool, NoError>? = nil, presentForExport: ((ViewController, Any?) -> Void)? = nil) -> Signal<Float, NoError> {
    let failed: (() -> Void)? = exportPermit.map { permit in { permit.revoke() } }
    let mediaData: Signal<(FetchMediaDataState, Bool), NoError> = fetchMediaData(context: context, userLocation: userLocation, customUserContentType: customUserContentType, mediaReference: mediaReference, onFailure: failed)
    let videoData: Signal<FetchMediaDataState?, NoError>
    if let video {
        videoData = fetchMediaData(context: context, userLocation: userLocation, customUserContentType: customUserContentType, mediaReference: video, onFailure: failed)
        |> map { state, _ in
            return state
        }
        |> map(Optional.init)
    } else {
        videoData = .single(nil)
    }

    let combined = combineLatest(
        queue: Queue.mainQueue(),
        mediaData,
        videoData
    )
    if let exportPermit {
        if let exportReference, exportReference.permit !== exportPermit {
            exportPermit.revoke()
            return .complete()
        }
        for reference in [mediaReference, video].compactMap({ $0 }) {
            if case let .message(message, _) = reference {
                guard let id = message.id, exportPermit.allows(accountId: context.account.id.int64, messageIds: [id], operation: .exportPreparation) else {
                    exportPermit.revoke()
                    return .complete()
                }
            }
        }
        let input = combined |> map { main, video -> ExteralessCameraRollInput in
            if let video {
                switch video {
                case let .progress(value): return .progress(value * 0.95)
                case let .data(value): if !value.isComplete { return .progress(0.95) }
                }
            }
            switch main.0 {
            case let .progress(value): return .progress(video == nil ? value : 0.95 + 0.05 * value)
            case let .data(value):
                guard value.isComplete else { return .progress(0) }
                let videoData: EngineMediaResource.ResourceData?
                if case let .data(data)? = video { videoData = data } else { videoData = nil }
                return .ready(ExteralessCameraRollData(main: value, video: videoData, isImage: main.1))
            }
        }
        let current = exportCurrent ?? { true }
        return exteralessCameraRollSave(input: input, permit: exportPermit, accountId: context.account.id.int64, owner: exportReference, current: current, validity: exportValidity, sinks: exteralessCameraRollNativeSinks(context: context, permit: exportPermit, current: current, present: presentForExport))
    }
    return combined
    |> mapToSignal { stateAndIsImage, videoStateAndIsImage -> Signal<Float, NoError> in
        let isImage = stateAndIsImage.1
        var mainData: EngineMediaResource.ResourceData?
        var videoData: EngineMediaResource.ResourceData?
        var waitForVideo = false
        if let videoState = videoStateAndIsImage {
            switch videoState {
            case let .progress(value):
                return .single(value * 0.95)
            case let .data(data):
                videoData = data
            }
            switch stateAndIsImage.0 {
            case let .progress(value):
                return .single(0.95 + 0.05 * value)
            case let .data(data):
                mainData = data
            }
            waitForVideo = true
        } else {
            switch stateAndIsImage.0 {
            case let .progress(value):
                return .single(value)
            case let .data(data):
                mainData = data
            }
        }
        if let mainData, mainData.isComplete, videoData != nil || !waitForVideo {
            return Signal<Float, NoError> { subscriber in
                DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { c, a in
                    context.sharedContext.presentGlobalController(c, a)
                }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
                    if !authorized {
                        subscriber.putCompletion()
                        return
                    }

                    let tempVideoPath = NSTemporaryDirectory() + "\(Int64.random(in: Int64.min ... Int64.max)).mp4"
                    if isImage, let videoData, let imageData = try? Data(contentsOf: URL(fileURLWithPath: mainData.path)) {
                        let id = UUID().uuidString

                        let jpegWithID = addAssetIdentifierToJPEG(imageData, assetIdentifier: id)!
                        let outputVideoURL = URL(fileURLWithPath: NSTemporaryDirectory() + "\(id).mov")

                        try? FileManager.default.copyItem(atPath: videoData.path, toPath: tempVideoPath)

                        addAssetIdentifierToVideo(inputURL: URL(fileURLWithPath: tempVideoPath), outputURL: outputVideoURL, assetIdentifier: id) { success in
                            guard success else { return }

                            PHPhotoLibrary.shared().performChanges({
                                let request = PHAssetCreationRequest.forAsset()

                                request.addResource(with: .photo, data: jpegWithID, options: nil)
                                request.addResource(with: .pairedVideo, fileURL: outputVideoURL, options: nil)
                            }, completionHandler: { _, error in
                                let _ = try? FileManager.default.removeItem(atPath: tempVideoPath)
                                subscriber.putNext(1.0)
                                subscriber.putCompletion()
                            })
                        }
                    } else {
                        PHPhotoLibrary.shared().performChanges({
                            if isImage {
                                if let imageData = try? Data(contentsOf: URL(fileURLWithPath: mainData.path)) {
                                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: imageData, options: nil)
                                }
                            } else {
                                if let _ = try? FileManager.default.copyItem(atPath: mainData.path, toPath: tempVideoPath) {
                                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL(fileURLWithPath: tempVideoPath))
                                }
                            }
                        }, completionHandler: { _, error in
                            if let error {
                                print("\(error)")
                            }
                            let _ = try? FileManager.default.removeItem(atPath: tempVideoPath)
                            subscriber.putNext(1.0)
                            subscriber.putCompletion()
                        })
                    }
                })

                return ActionDisposable {
                }
            }
        } else {
            return .complete()
        }
    }
}

public func copyToPasteboard(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference) -> Signal<Void, NoError> {
    return fetchMediaData(context: context, userLocation: userLocation, mediaReference: mediaReference)
    |> mapToSignal { state, isImage -> Signal<Void, NoError> in
        if case let .data(data) = state, data.isComplete {
            return Signal<Void, NoError> { subscriber in
                let pasteboard = UIPasteboard.general

                if mediaReference.media is TelegramMediaImage {
                    if let fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: .mappedIfSafe) {
                        pasteboard.setData(fileData, forPasteboardType: UTType.jpeg.identifier)
                    }
                }
                subscriber.putNext(Void())
                subscriber.putCompletion()

                return EmptyDisposable
            }
        } else {
            return .complete()
        }
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in return .complete() }
}

private func addAssetIdentifierToJPEG(_ imageData: Data, assetIdentifier: String) -> Data? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let uti = CGImageSourceGetType(source), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }

    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else {
        return nil
    }

    var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

    var maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
    maker["17"] = assetIdentifier
    metadata[kCGImagePropertyMakerAppleDictionary as String] = maker

    CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
    CGImageDestinationFinalize(destination)

    return mutableData as Data
}

@discardableResult
private func addAssetIdentifierToVideo(inputURL: URL, outputURL: URL, assetIdentifier: String, completion: @escaping (Bool) -> Void) -> Disposable {
    let asset = AVAsset(url: inputURL)

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        completion(false)
        return EmptyDisposable
    }

    let identifierItem = AVMutableMetadataItem()
    identifierItem.keySpace = .quickTimeMetadata
    identifierItem.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
    identifierItem.value = assetIdentifier as NSString

    let stillImageTimeItem = AVMutableMetadataItem()
    let keyStillImageTime = "com.apple.quicktime.still-image-time"
    let keySpaceQuickTimeMetadata = "mdta"
    stillImageTimeItem.key = keyStillImageTime as (NSCopying & NSObjectProtocol)?
    stillImageTimeItem.keySpace = AVMetadataKeySpace(rawValue: keySpaceQuickTimeMetadata)
    stillImageTimeItem.value = 0 as (NSCopying & NSObjectProtocol)?
    stillImageTimeItem.dataType = "com.apple.metadata.datatype.int8"

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mov
    exportSession.metadata = [identifierItem, stillImageTimeItem]
    exportSession.shouldOptimizeForNetworkUse = true

    exportSession.exportAsynchronously {
        completion(exportSession.status == .completed)
    }
    return ActionDisposable { exportSession.cancelExport() }
}
