import Foundation
import Darwin
import OpenStatC

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var cpuCores: [Double] = []
    @Published var memoryUsed: UInt64 = 0
    @Published var memoryActive: UInt64 = 0
    @Published var memoryWired: UInt64 = 0
    @Published var memoryCompressed: UInt64 = 0
    @Published var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var networkUpload: Double = 0
    @Published var networkDownload: Double = 0

    private var previousCPUTicks: [Int32] = []
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var lastNetworkTime: Date = Date()

    init() {
        let stats = getNetworkStats()
        previousBytesIn = stats.bytesIn
        previousBytesOut = stats.bytesOut
    }

    func update() {
        updateCPU()
        updateMemory()
        updateNetwork()
    }

    private func updateCPU() {
        var numCPUs: natural_t = 0
        var cpuInfoPtr: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &cpuInfoPtr, &numCPUInfo) == KERN_SUCCESS,
              let info = cpuInfoPtr else { return }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let count = Int(numCPUs)
        let stateCount = Int(CPU_STATE_MAX)
        let current = Array(UnsafeBufferPointer(start: info, count: count * stateCount))

        guard !previousCPUTicks.isEmpty, previousCPUTicks.count == current.count else {
            previousCPUTicks = current
            return
        }

        var totalUsed: Double = 0
        var totalAll: Double = 0
        var cores: [Double] = []

        for i in 0..<count {
            let o = i * stateCount
            let user   = Double(current[o + Int(CPU_STATE_USER)]   - previousCPUTicks[o + Int(CPU_STATE_USER)])
            let system = Double(current[o + Int(CPU_STATE_SYSTEM)] - previousCPUTicks[o + Int(CPU_STATE_SYSTEM)])
            let idle   = Double(current[o + Int(CPU_STATE_IDLE)]   - previousCPUTicks[o + Int(CPU_STATE_IDLE)])
            let nice   = Double(current[o + Int(CPU_STATE_NICE)]   - previousCPUTicks[o + Int(CPU_STATE_NICE)])

            let used  = max(0, user + system + nice)
            let total = max(0, used + idle)

            totalUsed += used
            totalAll  += total
            cores.append(total > 0 ? used / total * 100 : 0)
        }

        let overall = totalAll > 0 ? totalUsed / totalAll * 100 : 0

        cpuUsage = overall
        cpuCores = cores
        previousCPUTicks = current
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)
        let active     = UInt64(stats.active_count)      * page
        let wired      = UInt64(stats.wire_count)        * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used       = active + wired + compressed

        memoryUsed       = used
        memoryActive     = active
        memoryWired      = wired
        memoryCompressed = compressed
    }

    private func updateNetwork() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastNetworkTime)

        let stats = getNetworkStats()

        if elapsed > 0 {
            let downDelta = stats.bytesIn  >= previousBytesIn  ? stats.bytesIn  - previousBytesIn  : 0
            let upDelta   = stats.bytesOut >= previousBytesOut ? stats.bytesOut - previousBytesOut : 0

            networkDownload = Double(downDelta) / elapsed
            networkUpload   = Double(upDelta)   / elapsed
        }

        previousBytesIn  = stats.bytesIn
        previousBytesOut = stats.bytesOut
        lastNetworkTime  = now
    }
}
