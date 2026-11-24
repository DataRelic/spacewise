import Darwin

/// Opt-in development diagnostics. Values are process-wide, not scanner allocations.
/// No paths or names are retained. A failed OS query is nil, never a false zero.
public struct ScanMemorySample: Sendable, Codable {
    public let phase: String
    public let residentBytes: UInt64?
    public let peakRSSBytes: UInt64?
    public let nodeCount: Int
    public let nodeCapacity: Int
    public let nodeStride: Int
    public let pendingDirectories: Int
    public let hardLinkIdentities: Int

    public static func capture(
        phase: String, nodeCount: Int = 0, nodeCapacity: Int = 0,
        pendingDirectories: Int = 0, hardLinkIdentities: Int = 0
    ) -> Self {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let usageStatus = getrusage(RUSAGE_SELF, &usage)
        return Self(
            phase: phase, residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
            peakRSSBytes: usageStatus == 0 ? UInt64(usage.ru_maxrss) : nil,
            nodeCount: nodeCount, nodeCapacity: nodeCapacity,
            nodeStride: MemoryLayout<ScanNode>.stride, pendingDirectories: pendingDirectories,
            hardLinkIdentities: hardLinkIdentities)
    }
}
