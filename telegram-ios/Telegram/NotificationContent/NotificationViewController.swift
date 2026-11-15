import UIKit
import PasscodeCore
import ExteralessCore
import Display
import TelegramCore
import UserNotifications
import UserNotificationsUI
import TelegramUI
import BuildConfig

@objc(NotificationViewController)
@available(iOSApplicationExtension 10.0, iOS 10.0, *)
class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var impl: NotificationViewControllerImpl?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if self.impl == nil {
            let appBundleIdentifier = Bundle.main.bundleIdentifier!
            guard let lastDotRange = appBundleIdentifier.range(of: ".", options: [.backwards]) else {
                return
            }
            
            let baseAppBundleId = String(appBundleIdentifier[..<lastDotRange.lowerBound])
            
            let buildConfig = BuildConfig(baseAppBundleId: baseAppBundleId)
            
            let languagesCategory = "ios"
            
            let appGroupName = "group.\(baseAppBundleId)"
            try! PasscodeEnvironment.shared.configure(PasscodeConfiguration(appGroupIdentifier: appGroupName, processRole: .appExtension))
            let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
            
            guard let appGroupUrl = maybeAppGroupUrl else {
                return
            }
            
            let rootPath = appGroupUrl.path + "/telegram-data"
            do {
                try ExteralessFontFamily.prepare()
                try ClientSettings.shared.configure(storageURL: URL(fileURLWithPath: rootPath).appendingPathComponent("exteraless/client-settings.json"), durabilityRootURL: appGroupUrl)
                try ClientSettings.shared.register(PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions
                    + AppearanceMonetPolicy.definitions
                    + ChatFeatures.definitions + RetentionFeatures.definitions + ClientAPIFeatures.definitions
                    + CoreAppearanceFontFamilyPolicy.definitions)
                try ChatFeatures.migrateSettings(in: ClientSettings.shared)
                try ExteralessAccountRetentionEnvironment.shared.configure(ExteralessRetentionProcessConfiguration(
                    role: .shareExtension, snapshot: ClientSettings.shared.readSnapshot(), durabilityRootURL: appGroupUrl))
                try ExteralessHiddenAccounts.shared.configure(basePath: rootPath,
                    accessGroup: PasscodeEnvironment.shared.sharedAccessGroup(), isMainApp: false,
                    keychainScope: PasscodeEnvironment.shared.keychainScope, durabilityRootURL: appGroupUrl)
                try ExteralessHiddenAccounts.shared.reload()
                let configuration = ClientAPIConfigurationStore(settings: .shared, settingsSecrets: ClientSecrets.systemStore(),
                    vault: ClientAPIVault(storage: ClientAPIKeychain.storage(accessGroup: try PasscodeEnvironment.shared.sharedAccessGroup())))
                try ExteralessClientAPIEnvironment.shared.configure(builtinApiId: buildConfig.apiId,
                    builtinApiHash: buildConfig.apiHash, configuration: configuration)
            } catch {
                ExteralessAccountRetentionEnvironment.shared.setUnavailable()
                let message = (error as? ClientAPIError)?.errorDescription ?? "Unable to prepare account privacy and API settings."
                self.extensionContext?.cancelRequest(withError: NSError(domain: "ExteralessClientPreparation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
            
            let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
            let encryptionParameters: (Data, Data) = (deviceSpecificEncryptionParameters.key, deviceSpecificEncryptionParameters.salt)
            
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
            
            self.impl = NotificationViewControllerImpl(initializationData: NotificationViewControllerInitializationData(appBundleId: baseAppBundleId, appBuildType: buildConfig.isAppStoreBuild ? .public : .internal, appGroupPath: appGroupUrl.path, apiId: buildConfig.apiId, apiHash: buildConfig.apiHash, languagesCategory: languagesCategory, encryptionParameters: encryptionParameters, appVersion: appVersion, bundleData: buildConfig.bundleData(withAppToken: nil, tokenType: nil, tokenEnvironment: nil, signatureDict: nil), useBetaFeatures: !buildConfig.isAppStoreBuild), setPreferredContentSize: { [weak self] size in
                self?.preferredContentSize = size
            })
        }
        
        self.impl?.viewDidLoad(view: self.view)
    }
    
    func didReceive(_ notification: UNNotification) {
        self.impl?.didReceive(notification, view: self.view)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        self.impl?.viewWillTransition(to: size)
    }
}
