import Foundation
import Darwin
import OpenStatC

struct VolumeUsage: Identifiable {
    let id: String          // mount point
    let name: String
    let total: UInt64
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var ratio: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct BatterySnapshot {
    let present: Bool
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let timeToEmptyMin: Int   // -1 = N/A（系統計算中）
    let timeToFullMin: Int    // -1 = N/A
    let powerWatts: Double
    let cycleCount: Int
    let currentCapacityWh: Double
    let maxCapacityWh: Double

    /// 系統值不可用時，用剩餘電量 ÷ 瞬時功率估算放電剩餘分鐘。回傳 nil 表示無法估算。
    var estimatedTimeToEmptyMin: Int? {
        guard powerWatts > 0.1, currentCapacityWh > 0 else { return nil }
        let hours = currentCapacityWh / powerWatts
        let m = Int((hours * 60).rounded())
        return m > 0 ? m : nil
    }

    /// 充電時的剩餘時間估算（用「滿充 − 當前」÷ 功率）
    var estimatedTimeToFullMin: Int? {
        guard powerWatts > 0.1,
              maxCapacityWh > currentCapacityWh,
              currentCapacityWh > 0 else { return nil }
        let hours = (maxCapacityWh - currentCapacityWh) / powerWatts
        let m = Int((hours * 60).rounded())
        return m > 0 ? m : nil
    }
}

struct ProcessRow: Identifiable {
    let id: Int32         // pid
    let name: String
    let cpuPercent: Double
    let residentBytes: UInt64
}

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

    // 磁碟
    @Published var diskReadRate: Double = 0
    @Published var diskWriteRate: Double = 0
    @Published var volumes: [VolumeUsage] = []

    // GPU
    @Published var gpuAvailable: Bool = false
    @Published var gpuUsage: Double = 0
    @Published var gpuMemoryMB: Double = 0

    // 電池
    @Published var battery: BatterySnapshot = BatterySnapshot(
        present: false, percent: 0, isCharging: false, isPluggedIn: false,
        timeToEmptyMin: -1, timeToFullMin: -1, powerWatts: 0, cycleCount: 0,
        currentCapacityWh: 0, maxCapacityWh: 0)

    // Top Process
    @Published var topByCPU: [ProcessRow] = []
    @Published var topByMemory: [ProcessRow] = []

    private var previousCPUTicks: [Int32] = []
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var lastNetworkTime: Date = Date()

    private var previousDiskRead: UInt64 = 0
    private var previousDiskWrite: UInt64 = 0
    private var lastDiskTime: Date = Date()

    // pid -> 上次 CPU 累計時間 (ns)
    private var previousProcCPU: [Int32: UInt64] = [:]
    private var lastProcessTime: Date = Date()

    private let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)

    init() {
        let stats = getNetworkStats()
        previousBytesIn = stats.bytesIn
        previousBytesOut = stats.bytesOut

        let io = getDiskIOStats()
        previousDiskRead  = io.bytesRead
        previousDiskWrite = io.bytesWritten
    }

    func update() {
        updateCPU()
        updateMemory()
        updateNetwork()
        updateDisk()
        updateGPU()
        updateBattery()
        updateProcesses()
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

    // MARK: - Disk

    private func updateDisk() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDiskTime)

        let io = getDiskIOStats()
        if elapsed > 0 {
            let r = io.bytesRead     >= previousDiskRead  ? io.bytesRead     - previousDiskRead  : 0
            let w = io.bytesWritten  >= previousDiskWrite ? io.bytesWritten  - previousDiskWrite : 0
            diskReadRate  = Double(r) / elapsed
            diskWriteRate = Double(w) / elapsed
        }
        previousDiskRead  = io.bytesRead
        previousDiskWrite = io.bytesWritten
        lastDiskTime      = now

        var buf = Array(repeating: DiskVolumeInfo(), count: 8)
        let count = Int(buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            getDiskVolumes(ptr.baseAddress, Int32(ptr.count))
        })

        var vols: [VolumeUsage] = []
        for i in 0..<count {
            var v = buf[i]
            let mount: String = withUnsafePointer(to: &v.mountPoint) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            let name: String = withUnsafePointer(to: &v.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            vols.append(VolumeUsage(id: mount, name: name, total: v.totalBytes, free: v.freeBytes))
        }
        // 根目錄優先，其餘按容量排
        volumes = vols.sorted { a, b in
            if a.id == "/" { return true }
            if b.id == "/" { return false }
            return a.total > b.total
        }
    }

    // MARK: - GPU

    private func updateGPU() {
        let stats = getGPUStats()
        gpuAvailable = stats.available
        gpuUsage     = stats.utilization
        gpuMemoryMB  = stats.deviceMemMB
    }

    // MARK: - Battery

    private func updateBattery() {
        let b = getBatteryInfo()
        battery = BatterySnapshot(
            present: b.present,
            percent: Int(b.percent),
            isCharging: b.isCharging,
            isPluggedIn: b.isPluggedIn,
            timeToEmptyMin: Int(b.timeToEmptyMin),
            timeToFullMin: Int(b.timeToFullMin),
            powerWatts: b.powerWatts,
            cycleCount: Int(b.cycleCount),
            currentCapacityWh: b.currentCapacityWh,
            maxCapacityWh: b.maxCapacityWh
        )
    }

    // MARK: - Top Process

    private func updateProcesses() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProcessTime)
        lastProcessTime = now

        let cap = 512
        var buf = Array(repeating: ProcessSample(), count: cap)
        let n = Int(buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sampleProcesses(ptr.baseAddress, Int32(ptr.count))
        })
        guard n > 0 else { return }

        var current: [Int32: UInt64] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(n)

        let elapsedNs = max(elapsed, 0.001) * 1_000_000_000
        let firstSample = previousProcCPU.isEmpty

        for i in 0..<n {
            var s = buf[i]
            let pid = Int32(s.pid)
            current[pid] = s.cpuTimeNs

            let cpuPct: Double
            if firstSample {
                cpuPct = 0
            } else if let prev = previousProcCPU[pid], s.cpuTimeNs >= prev {
                cpuPct = Double(s.cpuTimeNs - prev) / elapsedNs * 100.0
            } else {
                cpuPct = 0
            }

            let name: String = withUnsafePointer(to: &s.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }

            rows.append(ProcessRow(
                id: pid,
                name: name.isEmpty ? "pid \(pid)" : name,
                cpuPercent: cpuPct,
                residentBytes: s.residentBytes
            ))
        }

        previousProcCPU = current
        topByCPU    = Array(rows.sorted { $0.cpuPercent    > $1.cpuPercent    }.prefix(5))
        topByMemory = Array(rows.sorted { $0.residentBytes > $1.residentBytes }.prefix(5))
    }
}
