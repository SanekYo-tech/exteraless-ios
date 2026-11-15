import ExteralessCore
import Foundation
import SwiftSignalKit

/// Application bootstrap boundary. Configure once after ClientSettings selects the
/// existing app-group path, before accountWithId can create any MTProto network.
public final class ExteralessClientAPIEnvironment: @unchecked Sendable {
    public static let shared = ExteralessClientAPIEnvironment()
    private let lock = NSLock()
    private var resolver: ClientAPILaunchResolver?
    private let errorValue = ValuePromise<ClientAPIError?>(nil, ignoreRepeated: true)

    public init() {}

    public var errors: Signal<ClientAPIError?, NoError> { errorValue.get() }

    public func configure(builtinApiId: Int32, builtinApiHash: String, configuration: ClientAPIConfigurationStore) throws {
        lock.lock()
        if resolver != nil { lock.unlock(); return } // A settings edit cannot relatch this launch.
        lock.unlock()
        do {
            try configuration.register()
            let candidate = try ClientAPILaunchResolver(builtinApiId: builtinApiId, builtinApiHash: builtinApiHash, configuration: configuration)
            lock.lock()
            if resolver == nil { resolver = candidate }
            lock.unlock()
        } catch {
            let error = (error as? ClientAPIError) ?? .settingsUnavailable
            errorValue.set(error)
            throw error
        }
    }

    /// The caller gets existingAuthorization from Postbox's actual state. Never
    /// infer it from a phone number, cached UI context or the selected account.
    public func arguments(_ arguments: NetworkInitializationArguments, recordId: Int64,
                          testingEnvironment: Bool, existingAuthorization: Bool) throws -> NetworkInitializationArguments {
        lock.lock()
        let resolver = resolver
        lock.unlock()
        do {
            guard let resolver else { throw ClientAPIError.bootstrapRequired }
            let scope = ClientAPIAccountScope(recordId: recordId, environment: testingEnvironment ? .test : .production)
            return try resolver.makeEnvironment(scope: scope, existingAuthorization: existingAuthorization) { apiId, apiHash in
                arguments.exteralessReplacingAPITuple(apiId: apiId, apiHash: apiHash)
            }
        } catch {
            let error = (error as? ClientAPIError) ?? .settingsUnavailable
            errorValue.set(error)
            throw error
        }
    }
}

extension NetworkInitializationArguments {
    /// Native factory only: preserve every non-identity network parameter exactly.
    /// Both Network and the Account/UnauthorizedAccount MUST receive this result.
    func exteralessReplacingAPITuple(apiId: Int32, apiHash: String) -> NetworkInitializationArguments {
        NetworkInitializationArguments(apiId: apiId, apiHash: apiHash, languagesCategory: languagesCategory,
            appVersion: appVersion, voipMaxLayer: voipMaxLayer, voipVersions: voipVersions,
            appData: appData, externalRequestVerificationStream: externalRequestVerificationStream,
            externalRecaptchaRequestVerification: externalRecaptchaRequestVerification,
            autolockDeadine: autolockDeadine, encryptionProvider: encryptionProvider, deviceModelName: deviceModelName,
            useBetaFeatures: useBetaFeatures, isICloudEnabled: isICloudEnabled, networkEngineFactory: networkEngineFactory)
    }
}
