import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import UniformTypeIdentifiers

final class ExteralessLyricsSelectionController: ExteralessChatTableController, UIDocumentPickerDelegate {
    private let track: PlayerLyricsTrack
    private let client: PlayerLyricsClient
    private let changed: () -> Void
    private var candidates: [PlayerLyricsCandidate]
    private var query: PlayerLyricsQuery
    private var overrideValue: PlayerLyricsOverride?
    private var busy = false
    private var observing = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let accountDisposable = MetaDisposable()
    private let playbackDisposable = MetaDisposable()

    init(context: AccountContext, track: PlayerLyricsTrack, candidates: [PlayerLyricsCandidate], changed: @escaping () -> Void) {
        self.track = track
        self.query = track.query
        self.client = ExteralessPlayerServices.lyrics(context: context)
        self.candidates = candidates
        self.changed = changed
        super.init(context: context, title: "Lyrics · " + track.query.title)
        accountInvalidated = { [weak self] in self?.cancelWork() }
        render()
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel(); accountDisposable.dispose(); playbackDisposable.dispose() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard accountIsValid else { return }
        guard !observing else { render(); return }
        observing = true
        accountDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            if value.primary?.account.id != self.context.account.id { self.invalidateAccount() }
        }))
        playbackDisposable.set((context.sharedContext.mediaManager.globalMediaPlayerState |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountIsValid else { return }
            guard let (account, value, _) = value, account.id == self.context.account.id, case let .state(state) = value,
                  let data = state.item.playbackData, case let .telegramFile(file, _, _) = data.source,
                  file.media.resource.id.stringRepresentation == self.track.resource,
                  state.status.duration.isFinite, Int64(max(0, min(PlayerLyricsLimits.maximumTrackDuration, state.status.duration)) * 1000) == self.track.durationMilliseconds else {
                self.invalidateAccount()
                self.sections = [ExteralessChatSection(rows: [ExteralessChatRow(id: "player.lyrics.changed", title: "Track changed", detail: "Reopen lyrics for the current track.", enabled: false)])]
                self.reloadRows()
                return
            }
        }))
        task = Task { [weak self, client, track] in
            let value = await client.userOverride(for: track)
            guard !Task.isCancelled, let self, self.accountIsValid else { return }
            self.overrideValue = value
            self.render()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A system file picker/alert may cover the screen; account and track
        // observers stay alive until the controller is released or invalidated.
    }

    private func cancelWork() { generation &+= 1; task?.cancel(); task = nil; busy = false }

    private func render() {
        guard accountIsValid else { return }
        let offset = overrideValue?.offset ?? 0
        var rows: [ExteralessChatRow] = [
            ExteralessChatRow(id: "player.lyrics.search", title: busy ? "Searching…" : "Search LRCLIB", detail: query.artist + " — " + query.title, enabled: !busy && ClientSettings.shared.bool("appearance.lrclibAllowed"), action: { [weak self] in self?.search() }),
            ExteralessChatRow(id: "player.lyrics.query", title: "Edit search title and artist", enabled: !busy, action: { [weak self] in self?.editQuery() }),
            ExteralessChatRow(id: "player.lyrics.import", title: "Import LRC or text file", enabled: !busy, action: { [weak self] in self?.importFile() }),
            ExteralessChatRow(id: "player.lyrics.delay", title: String(format: "Lyrics delay · %+.1f seconds", offset), detail: "Positive delay shows lyrics later. Applies only to this track and duration.", enabled: !busy, action: { [weak self] in self?.editOffset() }),
            ExteralessChatRow(id: "player.lyrics.reset", title: "Use automatic lyrics and timing", enabled: !busy && overrideValue != nil, action: { [weak self] in self?.save(nil) })
        ]
        if !ClientSettings.shared.bool("appearance.lrclibAllowed") {
            rows.insert(ExteralessChatRow(id: "player.lyrics.enable", title: "Enable online lyrics", detail: "Track metadata is sent to LRCLIB and LRCMUX.", action: { [weak self] in
                self?.writeSettings({ try ClientSettings.shared.set(.bool(true), for: "appearance.lrclibAllowed") }, completion: { [weak self] in self?.render() })
            }), at: 0)
        }
        sections = [ExteralessChatSection(rows: rows)]
        if !candidates.isEmpty {
            sections.append(ExteralessChatSection(title: "Select the correct recording", rows: candidates.enumerated().map { index, candidate in
                let duration = candidate.duration.map { String(format: " · %.0fs", $0) } ?? ""
                return ExteralessChatRow(id: "player.lyrics.candidate.\(index)", title: candidate.title, detail: candidate.artist + duration + " · " + candidate.lyrics.provider + (candidate.lyrics.synced ? " · Synced" : " · Plain"), checked: overrideValue?.lyrics == candidate.lyrics, enabled: !busy, action: { [weak self] in
                    guard let self else { return }
                    self.save(PlayerLyricsOverride(lyrics: candidate.lyrics, offset: self.overrideValue?.offset ?? 0))
                })
            }))
        }
        reloadRows()
    }

    private func search() {
        cancelWork()
        busy = true
        render()
        let generation = self.generation, query = self.query, allowed = ClientSettings.shared.bool("appearance.lrclibAllowed")
        task = Task { [weak self, client] in
            do {
                let candidates = try await client.search(query: query, onlineAllowed: allowed)
                guard !Task.isCancelled, let self, self.accountIsValid, self.generation == generation else { return }
                self.candidates = candidates
                self.busy = false
                self.render()
                if candidates.isEmpty { self.displayError("No matching recordings found.") }
            } catch {
                guard !Task.isCancelled, let self, self.accountIsValid, self.generation == generation else { return }
                self.busy = false
                self.render()
                self.displayError((error as? PlayerLyricsError)?.localizedDescription ?? "Couldn't load lyrics.")
            }
        }
    }

    private func save(_ value: PlayerLyricsOverride?) {
        cancelWork()
        busy = true
        render()
        let generation = self.generation
        task = Task { [weak self, client, track] in
            do {
                try await client.setOverride(value, for: track)
                guard !Task.isCancelled, let self, self.accountIsValid, self.generation == generation else { return }
                self.overrideValue = value
                self.busy = false
                self.render()
                self.changed()
            } catch {
                guard !Task.isCancelled, let self, self.accountIsValid, self.generation == generation else { return }
                self.busy = false
                self.render()
                self.displayError("Couldn't save this lyrics selection.")
            }
        }
    }

    private func editQuery() {
        let alert = UIAlertController(title: "Find a recording", message: "The track duration remains part of matching and selection identity.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Title"; $0.text = self.query.title }
        alert.addTextField { $0.placeholder = "Artist"; $0.text = self.query.artist }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Search", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, self.accountIsValid else { return }
            self.query = PlayerLyricsQuery(artist: alert?.textFields?[1].text, title: alert?.textFields?[0].text, album: nil, duration: Double(self.track.durationMilliseconds) / 1000)
            self.search()
        }))
        present(alert, animated: true)
    }

    private func editOffset() {
        let alert = UIAlertController(title: "Lyrics delay (seconds)", message: "−60 to +60. Positive values display and seek lyrics later.", preferredStyle: .alert)
        alert.addTextField { field in field.text = String(format: "%.1f", self.overrideValue?.offset ?? 0); field.keyboardType = .numbersAndPunctuation }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, self.accountIsValid else { return }
            guard let value = Double((alert?.textFields?.first?.text ?? "").replacingOccurrences(of: ",", with: ".")), value.isFinite, abs(value) <= PlayerLyricsLimits.maximumOffset else {
                self.displayError("Enter a delay from −60 to +60 seconds.")
                return
            }
            self.save(PlayerLyricsOverride(lyrics: self.overrideValue?.lyrics, offset: value))
        }))
        present(alert, animated: true)
    }

    private func importFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, accountIsValid else { return }
        cancelWork()
        busy = true
        render()
        let generation = self.generation
        task = Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) { () -> PlayerLyricsDocument? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? file.close() }
                guard let data = try? file.read(upToCount: PlayerLyricsLimits.textBytes + 1), data.count <= PlayerLyricsLimits.textBytes,
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
                return try? PlayerLyricsDocument.parse(text, source: .user, provider: "Your lyrics")
            }.value
            guard !Task.isCancelled, let self, self.accountIsValid, self.generation == generation else { return }
            self.busy = false
            if let parsed { self.save(PlayerLyricsOverride(lyrics: parsed, offset: self.overrideValue?.offset ?? 0)) }
            else { self.render(); self.displayError("The file has no readable lyrics, or exceeds 256 KiB.") }
        }
    }
}
