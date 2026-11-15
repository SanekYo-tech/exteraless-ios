import Darwin
import ExteralessCore
import Foundation

struct ExteralessPillMemory: Sendable {
    let processFootprint: UInt64?
    let systemFreePages: UInt64?
    let physicalMemory: UInt64
}

enum ExteralessPillMetrics {
    static let queue = DispatchQueue(label: "Exteraless.Pills.Metrics", qos: .utility)

    static func cpu() -> PillCPUCounters? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let seconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return PillCPUCounters(uptime: ProcessInfo.processInfo.systemUptime, processSeconds: seconds)
    }

    static func memory() -> ExteralessPillMemory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let minimumCount = mach_msg_type_number_t((MemoryLayout.offset(of: \task_vm_info_data_t.min_address) ?? MemoryLayout<task_vm_info_data_t>.size) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let footprint: UInt64? = result == KERN_SUCCESS && count >= minimumCount ? info.phys_footprint : nil
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var statistics = vm_statistics_data_t()
        var statisticsCount = mach_msg_type_number_t(MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)
        let statsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(statisticsCount)) { host_statistics(host, HOST_VM_INFO, $0, &statisticsCount) }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        var free: UInt64?
        if statsResult == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 {
            let bytes = UInt64(statistics.free_count).multipliedReportingOverflow(by: UInt64(pageSize))
            if !bytes.overflow { free = PillMetricPolicy.freeMemory(bytes: bytes.partialValue, total: total) }
        }
        return .init(processFootprint: footprint, systemFreePages: free, physicalMemory: total)
    }

    static func disk(path: String) -> (total: Int64, free: Int64)? {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = (values[.systemSize] as? NSNumber)?.int64Value, let free = (values[.systemFreeSize] as? NSNumber)?.int64Value,
              PillMetricPolicy.occupiedFraction(total: total, free: free) != nil else { return nil }
        return (total, free)
    }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    static func speed(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file) + "/s"
    }
}
