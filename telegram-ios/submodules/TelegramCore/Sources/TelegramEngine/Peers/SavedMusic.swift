import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

public enum AddSavedMusicError {
    case generic
}

public func revalidatedMusic<T>(account: Account, file: FileMediaReference, signal: @escaping (CloudDocumentMediaResource) -> Signal<T, MTRpcError>) -> Signal<T, MTRpcError> {
    guard let resource = file.media.resource as? CloudDocumentMediaResource else {
        return .fail(MTRpcError(errorCode: 500, errorDescription: "Internal"))
    }
    return signal(resource)
    |> `catch` { error -> Signal<T, MTRpcError> in
        if error.errorDescription == "FILE_REFERENCE_EXPIRED" {
            return revalidateMediaResourceReference(accountPeerId: account.peerId, postbox: account.postbox, network: account.network, revalidationContext: account.mediaReferenceRevalidationContext, info: TelegramCloudMediaResourceFetchInfo(reference: file.resourceReference(resource), preferBackgroundReferenceRevalidation: false, continueInBackground: false), resource: resource)
            |> mapError { _ -> MTRpcError in
                return MTRpcError(errorCode: 500, errorDescription: "Internal")
            }
            |> mapToSignal { result -> Signal<T, MTRpcError> in
                guard let resource = result.updatedResource as? CloudDocumentMediaResource else {
                    return .fail(MTRpcError(errorCode: 500, errorDescription: "Internal"))
                }
                return signal(resource)
            }
        } else {
            return .fail(error)
        }
    }
}

public final class SavedMusicIdsList: Codable, Equatable {
    public let items: [Int64]

    public init(items: [Int64]) {
        self.items = items
    }

    public static func ==(lhs: SavedMusicIdsList, rhs: SavedMusicIdsList) -> Bool {
        if lhs === rhs {
            return true
        }
        if lhs.items != rhs.items {
            return false
        }
        return true
    }
}

func _internal_getSavedMusicById(postbox: Postbox, network: Network, peer: PeerReference, file: TelegramMediaFile) -> Signal<TelegramMediaFile?, NoError> {
    let inputUser = peer.inputUser
    guard let inputUser, let resource = file.resource as? CloudDocumentMediaResource else {
        return .single(nil)
    }
    return network.request(Api.functions.users.getSavedMusicByID(id: inputUser, documents: [.inputDocument(.init(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference)))]))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.users.SavedMusic?, NoError> in
        return .single(nil)
    }
    |> map { result -> TelegramMediaFile? in
        if let result {
            switch result {
            case let .savedMusic(savedMusicData):
                if let file = savedMusicData.documents.first.flatMap({ telegramMediaFileFromApiDocument($0, altDocuments: nil) }) {
                    return file
                }
            default:
                break
            }
        }
        return nil
    }
}

func _internal_savedMusicIds(postbox: Postbox) -> Signal<Set<Int64>?, NoError> {
    let viewKey: PostboxViewKey = .preferences(keys: Set([PreferencesKeys.savedMusicIds()]))
    return postbox.combinedView(keys: [viewKey])
    |> map { views -> Set<Int64>? in
        guard let view = views.views[viewKey] as? PreferencesView else {
            return nil
        }
        guard let value = view.values[PreferencesKeys.savedMusicIds()]?.get(SavedMusicIdsList.self) else {
            return nil
        }
        return Set(value.items)
    }
}

func _internal_keepSavedMusicIdsUpdated(postbox: Postbox, network: Network, accountPeerId: EnginePeer.Id) -> Signal<Never, NoError> {
    let updateSignal = _internal_savedMusicIds(postbox: postbox)
    |> take(1)
    |> mapToSignal { list -> Signal<Never, NoError> in
        //TODO:release
        return network.request(Api.functions.account.getSavedMusicIds(hash: 0))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.account.SavedMusicIds?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Never, NoError> in
            guard let result else {
                return .complete()
            }
            return postbox.transaction { transaction in
                switch result {
                case let .savedMusicIds(savedMusicIdsData):
                    let ids = savedMusicIdsData.ids
                    let savedMusicIdsList = SavedMusicIdsList(items: ids)
                    transaction.setPreferencesEntry(key: PreferencesKeys.savedMusicIds(), value: PreferencesEntry(savedMusicIdsList))
                case .savedMusicIdsNotModified:
                    break
                }
            }
            |> ignoreValues
        }
    }
    
    return updateSignal
}

func managedSavedMusicIdsUpdates(postbox: Postbox, network: Network, accountPeerId: EnginePeer.Id) -> Signal<Never, NoError> {
    let poll = _internal_keepSavedMusicIdsUpdated(postbox: postbox, network: network, accountPeerId: accountPeerId)
    return (poll |> then(.complete() |> suspendAwareDelay(0.5 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

/// The acknowledgement is injected only at this accountless transaction seam in
/// tests. Production supplies the real, file-reference-revalidating RPC below.
func _internal_commitSavedMusicUpdate(postbox: Postbox, accountPeerId: EnginePeer.Id, file: FileMediaReference, afterFile: FileMediaReference?, isSaved: Bool, request: Signal<Bool, AddSavedMusicError>) -> Signal<Never, AddSavedMusicError> {
    let acknowledgement = request
    |> take(1)
    |> map { Optional.some($0) }
    |> then(.single(nil))
    |> take(1)
    return acknowledgement |> mapToSignal { accepted -> Signal<Never, AddSavedMusicError> in
        guard accepted == true else { return .fail(.generic) }
        return postbox.transaction { transaction in
            applySavedMusicUpdate(transaction: transaction, accountPeerId: accountPeerId, file: file, afterFile: afterFile, isSaved: isSaved)
        }
        |> castError(AddSavedMusicError.self)
        |> ignoreValues
    }
}

private func applySavedMusicUpdate(transaction: Transaction, accountPeerId: EnginePeer.Id, file: FileMediaReference, afterFile: FileMediaReference?, isSaved: Bool) {
    let previousIds = transaction.getPreferencesEntry(key: PreferencesKeys.savedMusicIds())?.get(SavedMusicIdsList.self)
    // IDs are independently cached. A cold profile-page cache must not keep the
    // player's heart stale, nor may a single mutation invent an unknown full list.
    if let previousIds {
        var ids = Set(previousIds.items)
        if isSaved { ids.insert(file.media.fileId.id) } else { ids.remove(file.media.fileId.id) }
        transaction.setPreferencesEntry(key: PreferencesKeys.savedMusicIds(), value: PreferencesEntry(SavedMusicIdsList(items: ids.sorted())))
    }
    var nextFirstFile: TelegramMediaFile?
    if isSaved {
        if let cachedSavedMusic = transaction.retrieveItemCacheEntry(id: entryId(peerId: accountPeerId))?.get(CachedProfileSavedMusic.self) {
            var updatedFiles = cachedSavedMusic.files
            var updatedCount = cachedSavedMusic.count
            
            if let fromIndex = updatedFiles.firstIndex(where: { $0.fileId == file.media.fileId }) {
                let anchorIdxOpt: Int? = afterFile.flatMap { af in
                    updatedFiles.firstIndex(where: { $0.fileId == af.media.fileId })
                }
                updatedFiles.remove(at: fromIndex)
                let insertIndex: Int
                if let anchorIndex = anchorIdxOpt {
                    if anchorIndex == fromIndex {
                        insertIndex = min(fromIndex + 1, updatedFiles.count)
                    } else {
                        let adjustedAnchor = anchorIndex > fromIndex ? (anchorIndex - 1) : anchorIndex
                        insertIndex = updatedFiles.index(after: adjustedAnchor)
                    }
                } else if afterFile != nil {
                    insertIndex = 0
                } else {
                    insertIndex = 0
                }
                
                updatedFiles.insert(file.media, at: insertIndex)
            } else {
                if let afterFile, let anchor = updatedFiles.firstIndex(where: { $0.fileId == afterFile.media.fileId }) {
                    updatedFiles.insert(file.media, at: updatedFiles.index(after: anchor))
                } else if afterFile != nil {
                    updatedFiles.append(file.media)
                } else {
                    updatedFiles.insert(file.media, at: 0)
                }
                if previousIds?.items.contains(file.media.fileId.id) != true { updatedCount += 1 }
            }
            
            if let entry = CodableEntry(CachedProfileSavedMusic(files: updatedFiles, count: updatedCount)) {
                transaction.putItemCacheEntry(id: entryId(peerId: accountPeerId), entry: entry)
            }
        }
    } else {
        if let cachedSavedMusic = transaction.retrieveItemCacheEntry(id: entryId(peerId: accountPeerId))?.get(CachedProfileSavedMusic.self) {
            let updatedFiles = cachedSavedMusic.files.filter { $0.fileId != file.media.fileId }
            let wasSaved = previousIds?.items.contains(file.media.fileId.id) ?? (updatedFiles.count != cachedSavedMusic.files.count)
            let updatedCount = max(0, cachedSavedMusic.count - (wasSaved ? 1 : 0))
            nextFirstFile = updatedFiles.first
            if let entry = CodableEntry(CachedProfileSavedMusic(files: updatedFiles, count: updatedCount)) {
                transaction.putItemCacheEntry(id: entryId(peerId: accountPeerId), entry: entry)
            }
        }
    }
    transaction.updatePeerCachedData(peerIds: Set([accountPeerId]), update: { _, data -> CachedPeerData? in
        guard let data = data as? CachedUserData else { return data }
        if isSaved, afterFile == nil { return data.withUpdatedSavedMusic(file.media) }
        if !isSaved, data.savedMusic?.fileId == file.media.fileId { return data.withUpdatedSavedMusic(nextFirstFile) }
        return data
    })
}

private func savedMusicUpdate(account: Account, file: FileMediaReference, afterFile: FileMediaReference?, isSaved: Bool) -> Signal<Never, AddSavedMusicError> {
    let request = revalidatedMusic(account: account, file: file, signal: { resource in
        var flags: Int32 = isSaved ? 0 : 1 << 0
        var afterId: Api.InputDocument?
        if isSaved, let afterFile, let resource = afterFile.media.resource as? CloudDocumentMediaResource {
            flags |= 1 << 1
            afterId = .inputDocument(.init(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference)))
        }
        return account.network.request(Api.functions.account.saveMusic(flags: flags, id: .inputDocument(.init(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference))), afterId: afterId))
    })
    |> mapError { _ -> AddSavedMusicError in .generic }
    |> map { result -> Bool in
        if case .boolTrue = result { return true }
        return false
    }
    return _internal_commitSavedMusicUpdate(postbox: account.postbox, accountPeerId: account.peerId, file: file, afterFile: afterFile, isSaved: isSaved, request: request)
}

func _internal_addSavedMusic(account: Account, file: FileMediaReference, afterFile: FileMediaReference?) -> Signal<Never, AddSavedMusicError> {
    savedMusicUpdate(account: account, file: file, afterFile: afterFile, isSaved: true)
}

func _internal_removeSavedMusic(account: Account, file: FileMediaReference) -> Signal<Never, NoError> {
    // Legacy callers keep their NoError signature, but failures no longer mutate
    // any cache. UI that reports an outcome uses updateSavedMusic below.
    savedMusicUpdate(account: account, file: file, afterFile: nil, isSaved: false)
    |> `catch` { _ in .complete() }
}

/// Checked native add/remove operation. Completion follows a true RPC response
/// and its Postbox commit; false, missing responses and RPC errors are failures.
public func updateSavedMusic(engine: TelegramEngine, file: FileMediaReference, isSaved: Bool) -> Signal<Never, AddSavedMusicError> {
    savedMusicUpdate(account: engine.account, file: file, afterFile: nil, isSaved: isSaved)
}

private final class CachedProfileSavedMusic: Codable {
    enum CodingKeys: String, CodingKey {
        case files
        case count
    }
    
    let files: [TelegramMediaFile]
    let count: Int32
    
    init(files: [TelegramMediaFile], count: Int32) {
        self.files = files
        self.count = count
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.files = try container.decode([TelegramMediaFile].self, forKey: .files)
        self.count = try container.decode(Int32.self, forKey: .count)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.files, forKey: .files)
        try container.encode(self.count, forKey: .count)
    }
}

private func entryId(peerId: EnginePeer.Id) -> ItemCacheEntryId {
    let cacheKey = ValueBoxKey(length: 8)
    cacheKey.setInt64(0, value: peerId.toInt64())
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedProfileSavedMusic, key: cacheKey)
}

public final class ProfileSavedMusicContext {
    public struct State: Equatable {
        public enum DataState: Equatable {
            case loading
            case ready(canLoadMore: Bool)
        }
        
        public var files: [TelegramMediaFile]
        public var count: Int32?
        public var dataState: DataState
    }
    
    private let queue: Queue = .mainQueue()
    private let account: Account
    public let peerId: EnginePeer.Id
    
    private let disposable = MetaDisposable()
    private let cacheDisposable = MetaDisposable()
    
    private var files: [TelegramMediaFile] = []
    private var count: Int32?
    private var dataState: ProfileSavedMusicContext.State.DataState = .ready(canLoadMore: true)
    
    private let stateValue = Promise<State>()
    public var state: Signal<State, NoError> {
        return self.stateValue.get()
    }
    
    public init(account: Account, peerId: EnginePeer.Id) {
        self.account = account
        self.peerId = peerId
                
        self.loadMore()
    }
    
    deinit {
        self.disposable.dispose()
        self.cacheDisposable.dispose()
    }
    
    public func reload() {
        self.files = []
        self.dataState = .ready(canLoadMore: true)
        self.loadMore(reload: true)
    }
    
    public func loadMore(reload: Bool = false) {
        let peerId = self.peerId
        let network = self.account.network
        let postbox = self.account.postbox
        let dataState = self.dataState
        let offset = Int32(self.files.count)
        
        guard case .ready(true) = dataState else {
            return
        }
        if self.files.isEmpty, !reload {
            self.cacheDisposable.set((postbox.transaction { transaction -> CachedProfileSavedMusic? in
                return transaction.retrieveItemCacheEntry(id: entryId(peerId: peerId))?.get(CachedProfileSavedMusic.self)
            } |> deliverOn(self.queue)).start(next: { [weak self] cachedSavedMusic in
                guard let self, let cachedSavedMusic else {
                    return
                }
                self.files = cachedSavedMusic.files
                self.count = cachedSavedMusic.count
                if case .loading = self.dataState {
                    self.pushState()
                }
            }))
        }
        
        self.dataState = .loading
        if !reload {
            self.pushState()
        }
        
        let signal = postbox.loadedPeerWithId(peerId)
        |> castError(MTRpcError.self)
        |> mapToSignal { peer -> Signal<([TelegramMediaFile], Int32), MTRpcError> in
            guard let inputUser = apiInputUser(peer) else {
                return .complete()
            }
            return network.request(Api.functions.users.getSavedMusic(id: inputUser, offset: offset, limit: 32, hash: 0))
            |> map { result -> ([TelegramMediaFile], Int32) in
                switch result {
                case let .savedMusic(savedMusicData):
                    return (savedMusicData.documents.compactMap { telegramMediaFileFromApiDocument($0, altDocuments: nil) }, savedMusicData.count)
                case let .savedMusicNotModified(savedMusicNotModifiedData):
                    return ([], savedMusicNotModifiedData.count)
                }
            }
        }
        
        self.disposable.set((signal
        |> deliverOn(self.queue)).start(next: { [weak self] files, count in
            guard let self else {
                return
            }
            if offset == 0 || reload {
                self.files = files
                self.cacheDisposable.set(self.account.postbox.transaction { transaction in
                    if let entry = CodableEntry(CachedProfileSavedMusic(files: files, count: count)) {
                        transaction.putItemCacheEntry(id: entryId(peerId: peerId), entry: entry)
                    }
                }.start())
            } else {
                self.files.append(contentsOf: files)
            }
            
            let updatedCount = max(Int32(self.files.count), count)
            self.count = updatedCount
            self.dataState = .ready(canLoadMore: count != 0 && updatedCount > self.files.count)
            self.pushState()
        }))
    }
        
    public func addMusic(file: FileMediaReference, afterFile: FileMediaReference? = nil, apply: Bool = true) -> Signal<Never, AddSavedMusicError> {
        if apply {
            return savedMusicUpdate(account: self.account, file: file, afterFile: afterFile, isSaved: true)
            |> deliverOn(self.queue)
            |> beforeCompleted { [weak self] in self?.applyAddedMusic(file: file, afterFile: afterFile) }
        }
        self.applyAddedMusic(file: file, afterFile: afterFile)
        return .complete()
    }

    private func applyAddedMusic(file: FileMediaReference, afterFile: FileMediaReference?) {
        var updatedFiles = self.files
    
        let fromIdx = updatedFiles.firstIndex { $0.fileId == file.media.fileId }
        let anchorIdxOpt = afterFile.flatMap { af in
            updatedFiles.firstIndex { $0.fileId == af.media.fileId }
        }
        
        if let fromIdx = fromIdx {
            updatedFiles.remove(at: fromIdx)
            
            let insertIdx: Int
            if let anchorIdx = anchorIdxOpt {
                if anchorIdx == fromIdx {
                    insertIdx = min(fromIdx + 1, updatedFiles.count)
                } else {
                    let adjustedAnchor = anchorIdx > fromIdx ? (anchorIdx - 1) : anchorIdx
                    insertIdx = updatedFiles.index(after: adjustedAnchor)
                }
            } else if afterFile != nil {
                insertIdx = updatedFiles.count
            } else {
                insertIdx = 0
            }
            updatedFiles.insert(file.media, at: insertIdx)
        } else {
            if let anchorIdx = anchorIdxOpt {
                updatedFiles.insert(file.media, at: updatedFiles.index(after: anchorIdx))
            } else if afterFile != nil {
                updatedFiles.append(file.media)
            } else {
                updatedFiles.insert(file.media, at: 0)
            }
            if let count = self.count {
                self.count = count + 1
            }
        }
        self.files = updatedFiles        
        self.pushState()
        
    }
    
    public func removeMusic(file: FileMediaReference) -> Signal<Never, NoError> {
        self.updateMusic(file: file, isSaved: false) |> `catch` { _ in .complete() }
    }

    public func updateMusic(file: FileMediaReference, isSaved: Bool) -> Signal<Never, AddSavedMusicError> {
        if isSaved { return self.addMusic(file: file) }
        return savedMusicUpdate(account: self.account, file: file, afterFile: nil, isSaved: false)
        |> deliverOn(self.queue)
        |> beforeCompleted { [weak self] in
            guard let self else { return }
            let previousCount = self.files.count
            self.files.removeAll(where: { $0.fileId == file.media.fileId })
            if let count = self.count, previousCount != self.files.count { self.count = max(0, count - 1) }
            self.pushState()
        }
    }
    
    private func pushState() {
        let state = State(
            files: self.files,
            count: self.count,
            dataState: self.dataState
        )
        self.stateValue.set(.single(state))
    }
}
