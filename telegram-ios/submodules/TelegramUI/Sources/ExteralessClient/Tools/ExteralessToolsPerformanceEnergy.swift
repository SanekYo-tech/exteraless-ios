import Display
import ExteralessCore
import Foundation
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

/// SharedAccountContext owns this process-wide presentation projection. No native
/// preferences are written: callbacks publish a transient copy to real consumers.
@MainActor
final class ExteralessToolsPerformanceEnergy {
    private static let automaticFPS = ProcessInfo.processInfo.processorCount > 2 ? 60 : 30
    private var settings: MediaAutoDownloadSettings
    private var isInForeground: Bool
    private let updated: (MediaAutoDownloadSettings, ToolsPerformancePublication) -> Void
    private var observation: ClientSettingsObservation?
    private var observers: [NSObjectProtocol] = []
    private var lastSettings: MediaAutoDownloadSettings?
    private var lastRevision: UInt64?
    private var disposed = false

    init(settings: MediaAutoDownloadSettings, isInForeground: Bool,
         updated: @escaping (MediaAutoDownloadSettings, ToolsPerformancePublication) -> Void) {
        self.settings = settings
        self.isInForeground = isInForeground
        self.updated = updated
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains(ToolsPerformancePolicy.key) else { return }
            // Read the latest coherent cache on main, never replay a queued value.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
                     UIDevice.batteryLevelDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func update(settings: MediaAutoDownloadSettings) {
        self.settings = settings
        refresh()
    }

    func update(isInForeground: Bool) {
        self.isInForeground = isInForeground
        refresh()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        observation?.cancel(); observation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func refresh() {
        guard !disposed else { return }
        let native = settings.energyUsageSettings
        let thermal: ToolsPerformancePolicy.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        let input = ToolsPerformancePolicy.Input(
            selection: .init(snapshot: ClientSettings.shared.readSnapshot()),
            nativeEnergy: .init(autoplayVideo: native.autoplayVideo, autoplayGif: native.autoplayGif,
                loopStickers: native.loopStickers, loopEmoji: native.loopEmoji, fullTranslucency: native.fullTranslucency,
                extendBackgroundWork: native.extendBackgroundWork, autodownloadInBackground: native.autodownloadInBackground),
            environment: .init(isInForeground: isInForeground, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                batterySaving: automaticEnergyUsageShouldBeOnNow(settings: settings), thermal: thermal,
                reduceMotion: UIAccessibility.isReduceMotionEnabled, reduceTransparency: UIAccessibility.isReduceTransparencyEnabled),
            automaticFramesPerSecond: Self.automaticFPS, maximumFramesPerSecond: min(60, mainWindowScreen.maximumFramesPerSecond))
        let publication = ToolsPerformancePolicyStore.shared.publish(input)
        let energy = publication.budget.energy
        var effective = settings
        // activationThreshold and all connection/category/download/privacy fields
        // keep their native values. The source settings remain the user's values.
        effective.energyUsageSettings = EnergyUsageSettings(activationThreshold: native.activationThreshold,
            autoplayVideo: energy.autoplayVideo, autoplayGif: energy.autoplayGif, loopStickers: energy.loopStickers,
            loopEmoji: energy.loopEmoji, fullTranslucency: energy.fullTranslucency,
            extendBackgroundWork: energy.extendBackgroundWork, autodownloadInBackground: energy.autodownloadInBackground)
        guard effective != lastSettings || publication.revision != lastRevision else { return }
        lastSettings = effective; lastRevision = publication.revision
        updated(effective, publication)
    }
}
