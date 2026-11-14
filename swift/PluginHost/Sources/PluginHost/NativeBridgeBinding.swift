#if canImport(CExteralessPythonBridge)
import Foundation
import CExteralessPythonBridge

/// Process-wide C -> Swift transport. The coordinator retains this binding
/// for the host lifetime and normally uninstalls after its workers stop.
///
/// C pins a separate retained context during every synchronous callback.
/// Detaching never waits for Python and releases that context only after the
/// last in-flight call. No Swift buffer is borrowed after a callback returns.
/// `@unchecked Sendable`: installation state is protected by `lock`; services
/// provide their own synchronization for concurrent OWN_GIL workers.
public final class NativeBridgeBinding: @unchecked Sendable {
    private let services: BridgeServices
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?

    public init(services: BridgeServices) {
        self.services = services
    }

    /// Idempotent for this binding; fails if another dispatcher is installed.
    /// This registers native pointers only and may precede Python startup.
    public func install() throws {
        lock.lock()
        defer { lock.unlock() }
        guard context == nil else { return }

        let pointer = Unmanaged.passRetained(NativeBridgeContext(services: services)).toOpaque()
        // Imported C typedefs are @convention(c); these functions capture
        // nothing and recover the retained object solely through the context.
        let callback: EXLPythonBridgeDispatcher = nativeBridgeDispatch
        let release: EXLPythonBridgeContextRelease = nativeBridgeReleaseContext
        let status = EXLPythonBridgeInstallDispatcher(callback, pointer, release)
        guard status == 0 else {
            Unmanaged<NativeBridgeContext>.fromOpaque(pointer).release()
            throw PluginHostError.runtimeFailure(
                "EXLPythonBridgeInstallDispatcher failed (status \(status))")
        }
        context = pointer
    }

    /// Stops accepting calls immediately. Active calls retain their services
    /// until they return; this method never waits for a GIL or a worker.
    public func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer = context else { return }
        context = nil
        _ = EXLPythonBridgeUninstallDispatcher(nativeBridgeDispatch, pointer)
    }

    deinit {
        if let pointer = context {
            _ = EXLPythonBridgeUninstallDispatcher(nativeBridgeDispatch, pointer)
        }
    }
}

private final class NativeBridgeContext: Sendable {
    let services: BridgeServices

    init(services: BridgeServices) {
        self.services = services
    }
}

private func nativeBridgeReleaseContext(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<NativeBridgeContext>.fromOpaque(context).release()
}

private func nativeBridgeDispatch(
    _ context: UnsafeMutableRawPointer?,
    _ requestBytes: UnsafePointer<CChar>?, _ requestCount: Int,
    _ pluginIDBytes: UnsafePointer<CChar>?, _ pluginIDCount: Int,
    _ response: UnsafeMutablePointer<EXLPythonBridgeBuffer>?
) -> CInt {
    guard let context, let requestBytes, requestCount > 0,
          let pluginIDBytes, pluginIDCount > 0, let response else { return -1 }
    return autoreleasepool {
        guard let request = String(
            bytes: UnsafeRawBufferPointer(start: requestBytes, count: requestCount), encoding: .utf8),
              let pluginID = String(
            bytes: UnsafeRawBufferPointer(start: pluginIDBytes, count: pluginIDCount), encoding: .utf8)
        else { return -1 }

        let owner = Unmanaged<NativeBridgeContext>.fromOpaque(context).takeUnretainedValue()
        // Runs on the current Python worker under its GIL. Services enqueue
        // reverse Python calls by pluginID/handle via the coordinator; this
        // binding never attaches another interpreter or dispatches to main.
        let reply = owner.services.dispatchJSON(request, pluginId: pluginID)
        return reply.utf8CString.withUnsafeBufferPointer { bytes in
            EXLPythonBridgeBufferCopy(response, bytes.baseAddress, bytes.count - 1)
        }
    }
}
#endif
