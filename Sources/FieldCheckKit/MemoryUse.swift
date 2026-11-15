import Darwin

/// FieldCheck's own memory, as the system counts it against the app: the long check reports it, since
/// FieldTapeKit holds a whole file in memory to send it (`tape.track-limit`).
struct MemoryUse: Sendable, Hashable {
    /// Bytes in use now.
    let footprint: Int
    /// The most in use at once since the app started.
    let peak: Int

    /// Nil if the system doesn't say.
    static func now() -> MemoryUse? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryUse(footprint: Int(info.phys_footprint), peak: Int(info.ledger_phys_footprint_peak))
    }
}
