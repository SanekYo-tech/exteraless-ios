import UIKit
import PasscodeCore
import ExteralessCore
import Display
import TelegramUI
import BuildConfig
import ShareExtensionContext
import SwiftSignalKit
import TelegramCore

@objc(ShareRootController)
class ShareRootController: UIViewController {
    private var impl: ShareRootControllerImpl?
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        self.modalPresentationStyle = .fullScreen
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        super.loadView()
        
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
                let exteralessDirectory = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent("exteraless", isDirectory: true)
                try ChatTrackingRulesStore.shared.configure(overrideURL: exteralessDirectory.appendingPathComponent("adguard_url_tracking.txt"), bundledURL: Bundle.main.url(forResource: "adguard_url_tracking", withExtension: "txt"))
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
            
            self.impl = ShareRootControllerImpl(initializationData: ShareRootControllerInitializationData(appBundleId: baseAppBundleId, appBuildType: buildConfig.isAppStoreBuild ? .public : .internal, appGroupPath: appGroupUrl.path, apiId: buildConfig.apiId, apiHash: buildConfig.apiHash, languagesCategory: languagesCategory, encryptionParameters: encryptionParameters, appVersion: appVersion, bundleData: buildConfig.bundleData(withAppToken: nil, tokenType: nil, tokenEnvironment: nil, signatureDict: nil), useBetaFeatures: !buildConfig.isAppStoreBuild, makeTempContext: { accountManager, appLockContext, applicationBindings, InitialPresentationDataAndSettings, networkArguments in
                return makeTempContext(
                    sharedContainerPath: appGroupUrl.path,
                    rootPath: rootPath,
                    appGroupPath: appGroupUrl.path,
                    accountManager: accountManager,
                    appLockContext: appLockContext,
                    encryptionParameters: EngineValueBoxEncryptionParameters(
                        forceEncryptionIfNoSet: false,
                        key: EngineValueBoxEncryptionParameters.Key(data: encryptionParameters.0)!,
                        salt: EngineValueBoxEncryptionParameters.Salt(data: encryptionParameters.1)!
                    ),
                    applicationBindings: applicationBindings,
                    initialPresentationDataAndSettings: InitialPresentationDataAndSettings,
                    networkArguments: networkArguments,
                    buildConfig: buildConfig
                )
            }), getExtensionContext: { [weak self] in
                return self?.extensionContext
            })
            
            self.impl?.openUrl = { [weak self] url in
                guard let self, let url = URL(string: url) else {
                    return
                }
                let _ = self.openURL(url)
            }
        }
        
        self.impl?.loadView()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.impl?.viewWillAppear()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.impl?.viewWillDisappear()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.impl?.viewWillDisappear()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.impl?.viewDidLayoutSubviews(view: self.view, traitCollection: self.traitCollection)
    }
    
    @objc func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:], completionHandler: nil)
                    return true
                } else {
                    return application.perform(#selector(openURL(_:)), with: url) != nil
                }
            }
            responder = responder?.next
        }
        return false
    }
}
