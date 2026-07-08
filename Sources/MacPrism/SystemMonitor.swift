import Foundation
import Darwin
import os
import MacPrismC

/// 效能除錯用 logger。預設只在「單輪 update 超過門檻」時記錄，正常情況近乎零成本。
/// 檢視方式：Console.app 篩 subsystem「com.macprism.app」、category「perf」，
/// 或終端機 `log show --predicate 'subsystem == "com.macprism.app"' --last 10m`。
private let perfLog = Logger(subsystem: "com.macprism.app", category: "perf")

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
    let healthPercent: Int    // 電池健康度 0-100；0 = 無法取得

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

struct TempReading: Identifiable {
    let id = UUID()
    let name: String
    let celsius: Double
}

struct FanRow: Identifiable {
    let id: Int
    let rpm: Int
    let minRPM: Int
    let maxRPM: Int
}

struct BTDeviceRow: Identifiable {
    let id = UUID()
    let name: String
    let percent: Int
}

struct IOSDeviceRow: Identifiable {
    let id = UUID()
    let name: String
    let kind: String        // iPhone / iPad
    let percent: Int        // -1 = 未信任，無法取得
    let isCharging: Bool
    let fullyCharged: Bool
    let paired: Bool        // false = 需在裝置上點「信任」
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
        currentCapacityWh: 0, maxCapacityWh: 0, healthPercent: 0)
    @Published var btDevices: [BTDeviceRow] = []
    @Published var iosDevices: [IOSDeviceRow] = []

    // Top Process
    @Published var topByCPU: [ProcessRow] = []
    @Published var topByMemory: [ProcessRow] = []

    // 感測器
    @Published var temperatures: [TempReading] = []
    @Published var fans: [FanRow] = []

    // 記憶體進階
    @Published var swapUsedBytes: UInt64 = 0
    @Published var swapTotalBytes: UInt64 = 0
    @Published var memoryPressureLevel: Int = 1   // 1 正常 / 2 警告 / 4 危急

    // 系統
    @Published var loadAverage: [Double] = []
    @Published var uptimeSeconds: Double = 0

    /// 最高溫度（感測器已依溫度排序）
    var maxTemperature: Double? { temperatures.first?.celsius }
    var sensorsAvailable: Bool { !temperatures.isEmpty || !fans.isEmpty }

    // 歷史走勢（最近 60 筆 ≈ 2 分鐘）
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var netUpHistory: [Double] = []
    @Published var netDownHistory: [Double] = []
    private let historyLimit = 60

    private var tickCount = 0

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

        // 開始監看 USB 連接的 iOS 裝置（須在具 run loop 的主執行緒）
        startIOSDeviceMonitoring()
    }

    func update() {
        let tickStart = DispatchTime.now()
        var marks: [(String, Double)] = []
        func step(_ name: String, _ body: () -> Void) {
            let s = DispatchTime.now()
            body()
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- s.uptimeNanoseconds) / 1_000_000
            marks.append((name, ms))
        }

        step("cpu",     updateCPU)
        step("memory",  updateMemory)
        step("network", updateNetwork)
        step("disk",    updateDisk)
        step("gpu",     updateGPU)
        step("battery", updateBattery)
        step("processes", updateProcesses)   // 每 2 秒固定取樣，維持 CPU% 的 2 秒基準準確
        step("sensors", updateSensors)
        step("load",    updateLoadAndUptime)
        if tickCount % 5 == 0 { step("bluetooth", updateBluetooth) }   // 藍牙約每 10 秒掃一次
        if tickCount % 5 == 0 { step("iosDevices", updateIOSDevices) } // iOS 裝置約每 10 秒讀一次（含 USB session，勿高頻）
        tickCount += 1
        pushHistory()

        let totalMs = Double(DispatchTime.now().uptimeNanoseconds &- tickStart.uptimeNanoseconds) / 1_000_000
        if totalMs > 50 {   // 2 秒週期下，>50ms ≈ 持續 >2.5% CPU，值得記錄
            let detail = marks.sorted { $0.1 > $1.1 }.prefix(3)
                .map { "\($0.0) \(String(format: "%.1f", $0.1))ms" }
                .joined(separator: ", ")
            perfLog.warning("update tick \(String(format: "%.1f", totalMs), privacy: .public)ms 最重: \(detail, privacy: .public)")
        }
    }

    /// 把本輪數值推入歷史環形緩衝
    private func pushHistory() {
        func push(_ value: Double, _ arr: inout [Double]) {
            arr.append(value)
            if arr.count > historyLimit { arr.removeFirst() }
        }
        push(cpuUsage, &cpuHistory)
        push(Double(memoryUsed) / Double(max(1, memoryTotal)) * 100, &memHistory)
        push(gpuUsage, &gpuHistory)
        push(networkUpload,   &netUpHistory)
        push(networkDownload, &netDownHistory)
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

        // Swap 使用量
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapTotalBytes = swap.xsu_total
            swapUsedBytes  = swap.xsu_used
        }

        // 記憶體壓力等級（1 正常 / 2 警告 / 4 危急）
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            memoryPressureLevel = Int(level)
        }
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
            // 友善卷宗名稱（如「Macintosh HD」），取不到時退回掛載點
            let volumeName = (try? URL(fileURLWithPath: mount)
                .resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
            vols.append(VolumeUsage(id: mount, name: volumeName, total: v.totalBytes, free: v.freeBytes))
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
            maxCapacityWh: b.maxCapacityWh,
            healthPercent: Int(b.healthPercent)
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

    // MARK: - 感測器（溫度 / 風扇）

    private func updateSensors() {
        var tbuf = [TempSensor](repeating: TempSensor(), count: 64)
        let tn = Int(tbuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            getTemperatureSensors(ptr.baseAddress, Int32(ptr.count))
        })
        var temps: [TempReading] = []
        temps.reserveCapacity(tn)
        for i in 0..<tn {
            var t = tbuf[i]
            let name = withUnsafePointer(to: &t.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 80) { String(cString: $0) }
            }
            temps.append(TempReading(name: name, celsius: t.celsius))
        }
        temperatures = temps.sorted { $0.celsius > $1.celsius }

        var fbuf = [FanReading](repeating: FanReading(), count: 8)
        let fn = Int(fbuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            getFans(ptr.baseAddress, Int32(ptr.count))
        })
        fans = (0..<fn).map { i in
            FanRow(id: i, rpm: Int(fbuf[i].actualRPM),
                   minRPM: Int(fbuf[i].minRPM), maxRPM: Int(fbuf[i].maxRPM))
        }
    }

    // MARK: - 藍牙裝置電量

    private func updateBluetooth() {
        var buf = [BTDevice](repeating: BTDevice(), count: 16)
        let n = Int(buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            getBluetoothBatteries(ptr.baseAddress, Int32(ptr.count))
        })
        var rows: [BTDeviceRow] = []
        var seen = Set<String>()
        for i in 0..<n {
            var d = buf[i]
            let name = withUnsafePointer(to: &d.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 80) { String(cString: $0) }
            }
            if name.isEmpty || seen.contains(name) { continue }
            seen.insert(name)
            rows.append(BTDeviceRow(name: name, percent: Int(d.percent)))
        }
        btDevices = rows
    }

    // MARK: - iOS 裝置（USB 連接的 iPhone / iPad）

    private func updateIOSDevices() {
        var buf = [IOSDeviceInfo](repeating: IOSDeviceInfo(), count: 8)
        let n = Int(buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            getIOSDevices(ptr.baseAddress, Int32(ptr.count))
        })
        var rows: [IOSDeviceRow] = []
        for i in 0..<n {
            var d = buf[i]
            let name = withUnsafePointer(to: &d.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 80) { String(cString: $0) }
            }
            let kind = withUnsafePointer(to: &d.kind) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            rows.append(IOSDeviceRow(
                name: name,
                kind: kind,
                percent: Int(d.percent),
                isCharging: d.isCharging,
                fullyCharged: d.fullyCharged,
                paired: d.paired
            ))
        }
        iosDevices = rows
    }

    // MARK: - Load Average / Uptime

    private func updateLoadAndUptime() {
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != -1 {
            loadAverage = loads
        }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 {
            uptimeSeconds = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
    }
}
