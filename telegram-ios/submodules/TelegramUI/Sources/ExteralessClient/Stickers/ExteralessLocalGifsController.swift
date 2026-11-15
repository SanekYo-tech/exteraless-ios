import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
final class ExteralessLocalGifsController: ExteralessSettingsListController {
    private var disposable: Disposable?
    private let clearDisposable = MetaDisposable()
    private var count: Int?

    override init(context: AccountContext) {
        super.init(context: context)
        self.title = "Local GIF Library"
        self.disposable = (exteralessLocalGifCount(engine: context.engine) |> deliverOnMainQueue).start(next: { [weak self] count in self?.count = count; self?.render() }, error: { [weak self] error in self?.errorText = error.localizedDescription; self?.render() })
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.disposable?.dispose(); self.clearDisposable.dispose() }

    override func render() {
        var toggle = ExteralessSettingsRow(id: "local", title: "Keep Additional GIFs Locally")
        toggle.enabled = !self.isBusy
        toggle.toggle = (StickerPolicy().localGifs, { [weak self] value in self?.perform({ try ClientSettings.shared.set(.bool(value), for: "chats.unlimitedSavedGifs") }, completion: { _ in }) })
        var clear = ExteralessSettingsRow(id: "clear", title: "Clear Local GIF Library", detail: self.count.map { "\($0) locally saved GIFs" })
        clear.style = .destructive
        clear.action = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "Clear Local GIF Library?", message: "Telegram's cloud-saved GIFs are kept.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
                guard let self else { return }
                self.clearDisposable.set(exteralessClearLocalGifs(engine: self.context.engine).start())
            }))
            self.context.sharedContext.applicationBindings.presentNativeController(alert)
        }
        self.setSections([ExteralessSettingsSection(footer: "Additional GIFs appear in the keyboard's Saved GIFs tab. Disabling the option restores the cloud list without deleting local items. Media remain subject to Telegram availability and the normal media cache.", rows: [toggle, clear])] + self.operationSections())
    }
}
