import AccountContext
import AnimationCache
import ClientHarnessAccount
import DCTAnimationCacheImpl
import DCTMultiAnimationRendererImpl
import Display
import Foundation
import LottieSettings
import MultiAnimationRenderer
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

/// Explicit fixture service boundary: real disposable account, window, presentation
/// and source-required offline bubble inputs. Unprovided app services are named
/// traps. No network/media command is supplied by the renderer fixture.
public final class ClientHarnessAccountContext: AccountContext {
    private let fixture: HarnessAccount
    public let shared: ClientHarnessSharedContext
    private let content = Atomic(value: ContentSettings.default)
    private let appConfiguration = Atomic(value: AppConfiguration.defaultValue)
    private let cache: AnimationCache?
    private let renderer: MultiAnimationRenderer?
    private let localFetchStatus: FetchManager?
    private let composerRendering: Bool
    private let limits = Atomic(value: LimitsConfiguration.defaultValue)

    public init(fixture: HarnessAccount, window: Window1, dark: Bool, bubbleRendering: Bool = false, composerRendering: Bool = false) {
        self.fixture = fixture
        self.composerRendering = composerRendering
        self.shared = ClientHarnessSharedContext(fixture: fixture, window: window, dark: dark, composerRendering: composerRendering)
        if bubbleRendering || composerRendering {
            let media = fixture.account.postbox.mediaBox
            self.cache = DCTAnimationCacheImpl(basePath: media.basePath + "/ui-harness-animation-cache",
                allocateTempFile: { TempBox.shared.tempFile(fileName: "fixture").path },
                updateStorageStats: { path, size in
                    if let bytes = path.data(using: .utf8) { media.cacheStorageBox.update(id: bytes, size: size) }
                })
            self.renderer = DCTMultiAnimationRendererImpl()
            self.localFetchStatus = bubbleRendering ? ClientHarnessFetchStatus(postbox: fixture.account.postbox) : nil
        } else {
            self.cache = nil
            self.renderer = nil
            self.localFetchStatus = nil
        }
        HarnessProcessRetainer.retain(self)
    }

    public var account: Account { self.fixture.account }
    public var engine: TelegramEngine { TelegramEngine(account: self.fixture.account) }
    public var sharedContext: SharedAccountContext { self.shared }

    // Stock offline rendering inputs read by the real Feed bubble/reply/reaction
    // nodes. No AccountContext service is populated merely to silence a trap.
    public var currentContentSettings: Atomic<ContentSettings> { self.content }
    public var currentAppConfiguration: Atomic<AppConfiguration> { self.appConfiguration }
    public var fetchManager: FetchManager {
        guard let status = self.localFetchStatus else { fatalError("client-ui-harness: fetchStatus requires the bubble fixture") }
        return status
    }
    public var animationCache: AnimationCache {
        guard let cache = self.cache else { fatalError("client-ui-harness: animationCache requires the bubble fixture") }
        return cache
    }
    public var animationRenderer: MultiAnimationRenderer {
        guard let renderer = self.renderer else { fatalError("client-ui-harness: animationRenderer requires the bubble fixture") }
        return renderer
    }
    public var lottieRenderingSettings: LottieRenderingSettings { LottieRenderingSettings(backend: .tlottie) }
    public var peerNameColors: PeerNameColors {
        PeerNameColors.with(availableReplyColors: EngineAvailableColorOptions(hash: 0, options: []),
            availableProfileColors: EngineAvailableColorOptions(hash: 0, options: []))
    }
    public func getAppConfigValue(_ key: String) -> Any? { self.appConfiguration.with { $0 }.data?[key] }

    public var currentLimitsConfiguration: Atomic<LimitsConfiguration> {
        precondition(self.composerRendering, "client-ui-harness: limits require the composer fixture")
        return self.limits
    }
    public var userLimits: EngineConfiguration.UserLimits {
        precondition(self.composerRendering, "client-ui-harness: userLimits require the composer fixture")
        return EngineConfiguration.UserLimits(UserLimitsConfiguration.defaultValue)
    }
    public var isPremium: Bool {
        precondition(self.composerRendering, "client-ui-harness: premium requires the explicit ordinary-user composer fixture")
        return false
    }
    public var isFrozen: Bool {
        precondition(self.composerRendering, "client-ui-harness: freeze state requires the composer fixture")
        return AccountFreezeConfiguration.with(appConfiguration: self.appConfiguration.with { $0 }).freezeUntilDate != nil
    }
    public var animatedEmojiStickersValue: [String: [StickerPackItem]] {
        precondition(self.composerRendering, "client-ui-harness: emoji inventory requires the empty offline composer fixture")
        return [:]
    }
}

public final class ClientHarnessSharedContext: SharedAccountContext {
    private let fixture: HarnessAccount
    private let window: Window1
    private let current: Atomic<PresentationData>
    private let updates = Promise<PresentationData>()
    private let composerRendering: Bool
    private let chatSettings = Atomic(value: ChatSettings.defaultSettings)

    public init(fixture: HarnessAccount, window: Window1, dark: Bool, composerRendering: Bool = false) {
        self.fixture = fixture
        self.composerRendering = composerRendering
        self.window = window
        let initial = defaultPresentationData().withUpdated(theme: dark ? defaultDarkPresentationTheme : defaultPresentationTheme)
        self.current = Atomic(value: initial)
        self.updates.set(.single(initial))
    }

    public var accountManager: AccountManager<TelegramAccountManagerTypes> { self.fixture.accountManager }
    public var mainWindow: Window1? { self.window }
    public var currentPresentationData: Atomic<PresentationData> { self.current }
    public var presentationData: Signal<PresentationData, NoError> { self.updates.get() }
    public var energyUsageSettings: EnergyUsageSettings { EnergyUsageSettings.default }
    public var immediateExperimentalUISettings: ExperimentalUISettings {
        precondition(self.composerRendering, "client-ui-harness: editor backend requires the composer fixture")
        var settings = ExperimentalUISettings.defaultSettings
        settings.useInputDecEngine = true
        settings.inputDecTextBackend = true
        return settings
    }
    public var currentChatSettings: Atomic<ChatSettings> {
        precondition(self.composerRendering, "client-ui-harness: chat settings require the composer fixture")
        return self.chatSettings
    }
    public var currentAutomaticMediaDownloadSettings: MediaAutoDownloadSettings {
        var value = MediaAutoDownloadSettings.defaultSettings
        value.cellular.enabled = false
        value.wifi.enabled = false
        value.downloadInBackground = false
        return value
    }

    /// Real PresentationData invalidation; controllers choose their own repaint.
    public func setDark(_ dark: Bool) {
        precondition(Thread.isMainThread)
        let updated = self.current.with { $0 }.withUpdated(theme: dark ? defaultDarkPresentationTheme : defaultPresentationTheme)
        _ = self.current.swap(updated)
        self.updates.set(.single(updated))
    }
}
