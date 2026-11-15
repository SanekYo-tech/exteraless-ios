import AccountContext
import Darwin
import Display
import ExteralessCore
import Foundation
import MetricKit
import UIKit

/// System-supplied metrics/crash diagnostics are cached locally, bounded to four
/// 1-MiB payloads. They are shared only from the diagnostics screen.
private final class ExteralessMetricCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var storageError: String?

    private func directory() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ToolsError.unavailable("Diagnostics storage is unavailable.")
        }
        return root.appendingPathComponent("exteraless/tools-diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads { store(payload.jsonRepresentation(), kind: "crash") }
    }

    func stop() { MXMetricManager.shared.remove(self) }
    func didReceive(_ payloads: [MXMetricPayload]) { for payload in payloads.suffix(4) { store(payload.jsonRepresentation(), kind: "metrics") } }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { for payload in payloads.suffix(4) { store(payload.jsonRepresentation(), kind: "crash") } }

    private func store(_ data: Data, kind: String) {
        guard data.count <= 1_024 * 1_024 else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = try directory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = "\(kind)-\(ToolsSHA256.hex(data).prefix(20)).json"
            let url = try ToolsFileSafety.checkedChild(name, root: directory)
            try data.write(to: url, options: .atomic)
            let files = try cachedFiles(directory)
            for file in files.dropFirst(4) { try FileManager.default.removeItem(at: file) }
            storageError = nil
        } catch { storageError = "System diagnostics could not be cached on this device." }
    }

    private func cachedFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { ($0.lastPathComponent.hasPrefix("crash-") || $0.lastPathComponent.hasPrefix("metrics-")) && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    func snapshot() -> (files: [URL], error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return ((try? cachedFiles(directory()).prefix(4).map { $0 }) ?? [], storageError)
    }
}

@MainActor final class ExteralessToolsDiagnostics: NSObject {
    private let metrics = ExteralessMetricCollector()
    private var link: CADisplayLink?
    private var stopTimer: Timer?
    private var profile = ToolsFrameProfile()
    private var startedAt: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var initialBattery: Float?
    private var wasMonitoringBattery = false
    private var active = false
    var onChange: (() -> Void)?
    var isProfiling: Bool { link != nil }

    func startCollection() {
        guard !active else { return }
        active = true
        metrics.start()
    }

    func stopCollection() {
        stopProfile()
        guard active else { return }
        active = false
        metrics.stop()
    }

    func startProfile() {
        guard link == nil else { return }
        profile = ToolsFrameProfile()
        startedAt = ProcessInfo.processInfo.systemUptime
        elapsed = 0
        wasMonitoringBattery = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        initialBattery = UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
        stopTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopProfile() }
        }
        onChange?()
    }

    func stopProfile() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        stopTimer?.invalidate()
        stopTimer = nil
        if let startedAt { elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt) }
        self.startedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = wasMonitoringBattery
        onChange?()
    }

    @objc private func tick(_ link: CADisplayLink) {
        profile.record(timestamp: link.timestamp, expectedInterval: max(0.001, link.targetTimestamp - link.timestamp))
    }

    func cachedMetrics() -> (files: [URL], error: String?) { metrics.snapshot() }

    func report() -> String {
        let process = ProcessInfo.processInfo
        var usage = rusage()
        let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = hasUsage ? Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000 : nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let duration = startedAt.map { process.systemUptime - $0 } ?? elapsed
        return [
            "Exteraless iOS diagnostics · \(ISO8601DateFormatter().string(from: Date()))",
            "Version: \(version) (\(build))",
            "Device family: \(UIDevice.current.model)",
            "OS: \(process.operatingSystemVersionString)",
            "Thermal state: \(process.thermalState.rawValue) · Low power: \(process.isLowPowerModeEnabled)",
            "Process CPU seconds (lifetime): \(cpu.map { String(format: "%.3f", $0) } ?? "unavailable")",
            "Peak resident memory bytes: \(hasUsage ? String(usage.ru_maxrss) : "unavailable")",
            "Profile duration: \(String(format: "%.2f", duration)) s\(isProfiling ? " (running)" : "")",
            "Battery at start: \(initialBattery.map { String(format: "%.0f%%", $0 * 100) } ?? "unavailable")",
            profile.report,
            "\nPlugin toggle durations (last 40):",
            ToolsToggleTraceBuffer.shared.snapshot().joined(separator: "\n"),
            "\nRPC method/code diagnostics (no raw error text):",
            ClientSettings.shared.bool("tools.showRPCError") ? ToolsRPCFailureBuffer.shared.snapshot().map { "\($0.method) · \($0.code)" }.joined(separator: "\n") : "disabled",
            "\nDisplay-link gaps measure main-thread callback cadence, not GPU render time. iOS does not expose Android /proc thread counters, battery current or wake-lock hooks. System MetricKit reports, when delivered, are available separately."
        ].joined(separator: "\n")
    }
}

final class ExteralessDiagnosticsController: ExteralessToolsListController {
    private let diagnostics: ExteralessToolsDiagnostics

    init(context: AccountContext, diagnostics: ExteralessToolsDiagnostics) {
        self.diagnostics = diagnostics
        super.init(context: context)
        self.title = "Diagnostics"
        diagnostics.onChange = { [weak self] in self?.render() }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        var sections = operationSections()
        sections.append(PluginListSection(title: "Local performance profile", footer: "A 20-second display-link capture. Reproduce the issue, return here and export the report. System diagnostics and reports are shared manually.", rows: [
            exteralessToolsAction("profile", diagnostics.isProfiling ? "Stop profile" : "Start 20-second profile", enabled: contextAvailable) { [weak self] in
                guard let self else { return }
                if self.diagnostics.isProfiling { self.diagnostics.stopProfile() } else { self.diagnostics.startProfile() }
            },
            exteralessToolsAction("report", "Export diagnostics…", enabled: !isBusy && contextAvailable) { [weak self] in self?.exportReport() },
            PluginListRow(id: "summary", title: diagnostics.report())
        ]))
        let cached = diagnostics.cachedMetrics()
        var rows = cached.files.map { file in
            exteralessToolsAction(file.lastPathComponent, file.lastPathComponent, enabled: !isBusy && contextAvailable) { [weak self] in
                guard let self else { return }
                self.runToolsOperation(title: "Preparing system diagnostics…", operation: {
                    try await Task.detached {
                        let bytes = try ToolsFileSafety.read(file, maximumBytes: 1_024 * 1_024)
                        return try exteralessToolsTemporaryFile(data: bytes, name: file.lastPathComponent)
                    }.value
                }, discard: exteralessToolsDiscardTemporaryFile, completion: { [weak self] url in
                    guard let self else { return }
                    exteralessToolsShare(url, from: self, removeOnCompletion: true)
                })
            }
        }
        if rows.isEmpty { rows.append(PluginListRow(id: "no-metrics", title: "No system diagnostic payload has been delivered yet")) }
        if let error = cached.error { rows.append(PluginListRow(id: "metric-error", title: error)) }
        sections.append(PluginListSection(title: "MetricKit · crash and energy reports", rows: rows))
        if ClientSettings.shared.bool("tools.showRPCError") {
            var failures = ToolsRPCFailureBuffer.shared.snapshot().enumerated().map { index, event in
                PluginListRow(id: "rpc-\(index)", title: "\(event.method) · \(event.code)")
            }
            failures.append(exteralessToolsAction("refresh-rpc", "Refresh RPC diagnostics", enabled: contextAvailable) { [weak self] in self?.render() })
            failures.append(exteralessToolsAction("clear-rpc", "Clear RPC diagnostics", enabled: contextAvailable) { [weak self] in
                ToolsRPCFailureBuffer.shared.clear(); self?.render()
            })
            sections.append(PluginListSection(title: "Recent RPC failure codes", footer: "Local, bounded and pull-based. Request parameters and raw server error text are not retained.", rows: failures))
        }
        setSections(sections)
    }

    private func exportReport() {
        let data = Data(diagnostics.report().utf8)
        runToolsOperation(title: "Preparing report…", operation: {
            try await Task.detached { try exteralessToolsTemporaryFile(data: data, name: "exteraless-diagnostics.txt") }.value
        }, discard: exteralessToolsDiscardTemporaryFile, completion: { [weak self] url in
            guard let self else { return }
            exteralessToolsShare(url, from: self, removeOnCompletion: true)
        })
    }
}
