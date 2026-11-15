import AccountContext
import Emoji
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

@MainActor
final class ExteralessEmojiPacks {
    struct Candidate {
        let data: Data
        let name: String
        let face: ExteralessEmojiFont
        let origin: EmojiFontOrigin
        let entry: EmojiCatalogEntry?
    }

    static let changed = Notification.Name("Exteraless.EmojiPackLibraryChanged")
    let context: AccountContext
    let store: EmojiPackStore
    private let owner: ExteralessEmojiFontOwner
    private let http = EmojiFontHTTPClient()
    private let network = MetaDisposable()
    private var task: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var lease = EmojiPackLease()
    private var generation: UInt64 = 0
    private var reloadGeneration: UInt64 = 0
    private(set) var active = true
    private(set) var isRemoteOperation = false
    private(set) var status: String?
    private(set) var errorText: String?
    private(set) var packs: [EmojiStoredPack] = []
    private(set) var catalog: EmojiCatalog?
    private(set) var candidate: Candidate?

    init(context: AccountContext) {
        self.context = context
        self.store = EmojiPackStore(root: URL(fileURLWithPath: context.account.basePath, isDirectory: true).appendingPathComponent("exteraless-emoji-packs", isDirectory: true), accountId: context.account.id.int64)
        self.owner = ExteralessEmojiRendering.shared.begin(accountId: context.account.id.int64)
    }

    func stop() {
        self.active = false
        self.cancel()
        self.reloadGeneration &+= 1
        self.reloadTask?.cancel()
        self.reloadTask = nil
        ExteralessEmojiRendering.shared.clear(owner: self.owner)
    }

    func cancelRemoteOperation() { if self.isRemoteOperation { self.cancel() } }

    func cancel() {
        self.generation &+= 1
        self.lease.invalidate()
        self.task?.cancel()
        self.task = nil
        self.network.set(nil)
        self.candidate = nil
        self.status = nil
        self.isRemoteOperation = false
        self.changed()
    }

    private func begin(_ title: String, remote: Bool = false) -> (UInt64, EmojiPackLease) {
        self.cancel()
        self.lease = EmojiPackLease()
        self.errorText = nil
        self.status = title
        self.isRemoteOperation = remote
        self.changed()
        return (self.generation, self.lease)
    }

    private func accepts(_ generation: UInt64) -> Bool { self.active && self.generation == generation }
    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }

    private func failed(_ error: Error, generation: UInt64) {
        guard self.accepts(generation) else { return }
        self.status = nil
        self.isRemoteOperation = false
        self.errorText = (error as? EmojiPackError)?.errorDescription ?? (error as? ClientSettingsError)?.errorDescription ?? "The emoji operation could not be completed."
        self.changed()
    }

    func reload() {
        guard self.active else { return }
        self.reloadGeneration &+= 1
        let generation = self.reloadGeneration
        self.reloadTask?.cancel()
        let policy = StickerPolicy()
        if policy.systemEmoji || policy.emojiPack.isEmpty || policy.emojiPack == "default" {
            ExteralessEmojiRendering.shared.apply(nil, owner: self.owner)
        }
        self.reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let packs = try await self.store.list()
                let catalog = try await self.store.catalog()
                guard self.active, self.reloadGeneration == generation, !Task.isCancelled else { return }
                self.packs = packs
                self.catalog = catalog
                if !policy.systemEmoji && !policy.emojiPack.isEmpty && policy.emojiPack != "default" {
                    guard let pack = packs.first(where: { $0.id == policy.emojiPack }) else { throw EmojiPackError.invalidCache }
                    let data = try await self.store.fontData(for: pack)
                    let owner = self.owner
                    let face = try await Task.detached(priority: .userInitiated) {
                        try ExteralessEmojiRendering.shared.prepare(data: data, fileExtension: pack.fileExtension, expectedSHA256: pack.sha256, owner: owner)
                    }.value
                    guard self.active, self.reloadGeneration == generation, !Task.isCancelled,
                          StickerPolicy().emojiPack == pack.id, !StickerPolicy().systemEmoji else { return }
                    guard ExteralessEmojiRendering.shared.apply(face, owner: self.owner) else { throw EmojiPackError.cancelled }
                }
                self.changed()
            } catch {
                guard self.active, self.reloadGeneration == generation, !Task.isCancelled else { return }
                ExteralessEmojiRendering.shared.apply(nil, owner: self.owner)
                self.errorText = (error as? EmojiPackError)?.errorDescription ?? "Stored emoji data could not be read."
                self.changed()
            }
        }
    }

    func refreshCatalog() {
        guard self.active, StickerPolicy().downloadEmojiPacks else { return }
        let (generation, _) = self.begin("Loading emoji catalog…", remote: true)
        self.network.set((exteralessLoadEmojiCatalog(engine: self.context.engine) |> deliverOnMainQueue).start(next: { [weak self] catalog in
            guard let self, self.accepts(generation) else { return }
            self.task = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    try await self.store.saveCatalog(catalog)
                    guard self.accepts(generation), StickerPolicy().downloadEmojiPacks else { return }
                    self.catalog = catalog
                    self.status = nil
                    self.isRemoteOperation = false
                    self.changed()
                } catch { self.failed(error, generation: generation) }
            }
        }, error: { [weak self] error in self?.failed(error, generation: generation) }))
    }

    func download(_ entry: EmojiCatalogEntry) {
        guard self.active, StickerPolicy().downloadEmojiPacks else { return }
        let (generation, _) = self.begin("Downloading \(entry.name)…", remote: true)
        self.network.set((exteralessEmojiFontDocument(engine: self.context.engine, entry: entry)
        |> mapToSignal { reference in
            exteralessStickerResourceData(engine: self.context.engine, file: reference, maximumBytes: EmojiPackLimits.fontBytes)
            |> map { ($0, ((reference.media.fileName ?? "") as NSString).pathExtension) }
        }
        |> deliverOnMainQueue).start(next: { [weak self] data, fileExtension in
            guard let self, self.accepts(generation), StickerPolicy().downloadEmojiPacks else { return }
            self.prepare(data: data, name: entry.name, fileExtension: fileExtension, origin: .telegram(source: EmojiCatalog.source, messageId: entry.file), entry: entry, expectedSHA256: entry.sha256, generation: generation)
        }, error: { [weak self] error in self?.failed(error, generation: generation) }))
    }

    func download(url: URL, expectedSHA256: String?) {
        guard self.active, StickerPolicy().downloadEmojiPacks else { return }
        let (generation, _) = self.begin("Downloading font…", remote: true)
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                let downloaded = try await self.http.download(url: url, expectedSHA256: expectedSHA256)
                guard self.accepts(generation), !Task.isCancelled, StickerPolicy().downloadEmojiPacks else { return }
                self.prepare(data: downloaded.data, name: downloaded.url.deletingPathExtension().lastPathComponent, fileExtension: downloaded.inspection.fileExtension, origin: .https(downloaded.url.absoluteString), entry: nil, expectedSHA256: downloaded.inspection.sha256, generation: generation)
            } catch { self.failed(error, generation: generation) }
        }
    }

    func importFile(_ url: URL) {
        guard self.active else { return }
        let (generation, _) = self.begin("Reading font…")
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try EmojiFontInspection.readFile(url)
                }.value
                guard self.accepts(generation), !Task.isCancelled else { return }
                self.prepare(data: data, name: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension, origin: .imported, entry: nil, expectedSHA256: nil, generation: generation)
            } catch { self.failed(error, generation: generation) }
        }
    }

    private func prepare(data: Data, name: String, fileExtension: String, origin: EmojiFontOrigin, entry: EmojiCatalogEntry?, expectedSHA256: String?, generation: UInt64) {
        let owner = self.owner
        self.status = "Checking font and rendering glyphs…"
        self.changed()
        self.task = Task { [weak self] in
            do {
                let face = try await Task.detached(priority: .userInitiated) {
                    try ExteralessEmojiRendering.shared.prepare(data: data, fileExtension: fileExtension, expectedSHA256: expectedSHA256, owner: owner)
                }.value
                guard let self, self.accepts(generation), !Task.isCancelled else { return }
                self.candidate = Candidate(data: data, name: name, face: face, origin: origin, entry: entry)
                self.status = nil
                self.changed()
            } catch { self?.failed(error, generation: generation) }
        }
    }

    func installCandidate() {
        guard self.active, let candidate = self.candidate else { return }
        let remote = self.isRemoteOperation
        guard !remote || StickerPolicy().downloadEmojiPacks else { self.cancel(); return }
        let (generation, lease) = self.begin("Saving font…", remote: remote)
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let inspection = candidate.face.inspection
                let pack = try await self.store.store(data: candidate.data, name: candidate.name, fileExtension: inspection.fileExtension, origin: candidate.origin, catalogEntry: candidate.entry, expectedSHA256: inspection.sha256)
                try await Task.detached(priority: .userInitiated) {
                    try lease.commit {
                        if remote && !StickerPolicy().downloadEmojiPacks { throw EmojiPackError.downloadsDisabled }
                        try ClientSettings.shared.applyPublic(["chats.emojiPack": .string(pack.id), "chats.useSystemEmoji": .bool(false)])
                    }
                }.value
                guard self.accepts(generation), !Task.isCancelled else { return }
                guard ExteralessEmojiRendering.shared.apply(candidate.face, owner: self.owner) else { throw EmojiPackError.registrationFailed }
                self.status = nil
                self.isRemoteOperation = false
                self.reload()
            } catch { self.failed(error, generation: generation) }
        }
    }

    func select(_ pack: EmojiStoredPack) {
        guard self.active else { return }
        let (generation, lease) = self.begin("Loading font…")
        let owner = self.owner
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.store.fontData(for: pack)
                let face = try await Task.detached(priority: .userInitiated) {
                    let face = try ExteralessEmojiRendering.shared.prepare(data: data, fileExtension: pack.fileExtension, expectedSHA256: pack.sha256, owner: owner)
                    try lease.commit { try ClientSettings.shared.applyPublic(["chats.emojiPack": .string(pack.id), "chats.useSystemEmoji": .bool(false)]) }
                    return face
                }.value
                guard self.accepts(generation), !Task.isCancelled else { return }
                guard ExteralessEmojiRendering.shared.apply(face, owner: owner) else { throw EmojiPackError.registrationFailed }
                self.status = nil
                self.changed()
            } catch { self.failed(error, generation: generation) }
        }
    }

    func selectNative(system: Bool) {
        guard self.active else { return }
        let (generation, lease) = self.begin("Restoring native emoji…")
        self.task = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try lease.commit {
                        if system { try ClientSettings.shared.set(.bool(true), for: "chats.useSystemEmoji") }
                        else { try ClientSettings.shared.applyPublic([:], resetting: ["chats.emojiPack", "chats.useSystemEmoji"]) }
                    }
                }.value
                guard let self, self.accepts(generation), !Task.isCancelled else { return }
                ExteralessEmojiRendering.shared.apply(nil, owner: self.owner)
                self.status = nil
                self.changed()
            } catch { self?.failed(error, generation: generation) }
        }
    }

    func remove(_ pack: EmojiStoredPack) {
        guard self.active else { return }
        let (generation, lease) = self.begin("Removing font…")
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try lease.commit {
                        if ClientSettings.shared.string("chats.emojiPack") == pack.id { try ClientSettings.shared.reset("chats.emojiPack") }
                    }
                }.value
                try Task.checkCancellation()
                try await self.store.remove(id: pack.id)
                guard self.accepts(generation) else { return }
                self.status = nil
                self.reload()
            } catch { self.failed(error, generation: generation) }
        }
    }

    func clearUnusedDownloads() {
        guard self.active else { return }
        let (generation, _) = self.begin("Clearing unused downloads…")
        let selected = ClientSettings.shared.string("chats.emojiPack")
        self.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.clearUnusedDownloads(selectedId: selected)
                guard self.accepts(generation) else { return }
                self.status = nil
                self.reload()
            } catch { self.failed(error, generation: generation) }
        }
    }
}
