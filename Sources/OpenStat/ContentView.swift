import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var tokenMonitor: TokenUsageMonitor
    @ObservedObject var settings: AppSettings
    @State private var topMode: TopMode = .cpu

    enum TopMode: String, CaseIterable { case cpu = "CPU", memory = "記憶體" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(settings.panelOrder, id: \.self) { item in
                        if settings.panelEnabled.contains(item) {
                            section(for: item)
                        }
                    }
                    if settings.panelEnabled.isEmpty { emptyState }
                }
                .padding(12)
            }
        }
        .frame(width: 320, height: 520)
    }

    @ViewBuilder
    private func section(for item: StatItem) -> some View {
        switch item {
        case .cpu:        cpuSection
        case .memory:     memorySection
        case .gpu:        if monitor.gpuAvailable { gpuSection }
        case .network:    networkSection
        case .disk:       diskSection
        case .battery:    if monitor.battery.present { batterySection }
        case .topProcess: topProcessSection
        case .tokenUsage: tokenUsageSection
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("尚未選擇任何顯示項目")
                .font(.subheadline)
            Text("右鍵 menu bar → 設定…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gauge.medium")
                .foregroundColor(.accentColor)
            Text("OpenStat")
                .font(.headline)
            Spacer()
            Button("結束") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - CPU

    private var cpuSection: some View {
        StatCard(title: "CPU", icon: "cpu") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("整體使用率")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", monitor.cpuUsage))
                        .font(.caption)
                        .foregroundColor(usageColor(monitor.cpuUsage, high: 80, mid: 50))
                        .monospacedDigit()
                }
                ProgressView(value: monitor.cpuUsage, total: 100)
                    .tint(usageColor(monitor.cpuUsage, high: 80, mid: 50))

                if !monitor.cpuCores.isEmpty {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(monitor.cpuCores.enumerated()), id: \.offset) { i, usage in
                            CoreBar(index: i + 1, usage: usage)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        StatCard(title: "記憶體", icon: "memorychip") {
            VStack(alignment: .leading, spacing: 6) {
                let ratio = Double(monitor.memoryUsed) / Double(max(1, monitor.memoryTotal))
                HStack {
                    Text(formatBytes(monitor.memoryUsed))
                        .font(.caption)
                        .monospacedDigit()
                    Text("/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatBytes(monitor.memoryTotal))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(String(format: "%.0f%%", ratio * 100))
                        .font(.caption)
                        .foregroundColor(ratioColor(ratio))
                        .monospacedDigit()
                }
                ProgressView(value: ratio, total: 1.0)
                    .tint(ratioColor(ratio))

                HStack(spacing: 12) {
                    MemLabel(color: .blue,   label: "Active",     value: formatBytes(monitor.memoryActive))
                    MemLabel(color: .orange, label: "Wired",      value: formatBytes(monitor.memoryWired))
                    MemLabel(color: .purple, label: "Compressed", value: formatBytes(monitor.memoryCompressed))
                }
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        StatCard(title: "網路", icon: "network") {
            HStack(spacing: 0) {
                NetStat(direction: "arrow.up", label: "上傳",
                        value: formatSpeed(monitor.networkUpload),
                        color: .orange)
                Divider().frame(height: 36)
                NetStat(direction: "arrow.down", label: "下載",
                        value: formatSpeed(monitor.networkDownload),
                        color: .cyan)
            }
        }
    }

    // MARK: - GPU

    private var gpuSection: some View {
        StatCard(title: "GPU", icon: "display") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("使用率").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", monitor.gpuUsage))
                        .font(.caption)
                        .foregroundColor(usageColor(monitor.gpuUsage, high: 80, mid: 50))
                        .monospacedDigit()
                }
                ProgressView(value: min(monitor.gpuUsage, 100), total: 100)
                    .tint(usageColor(monitor.gpuUsage, high: 80, mid: 50))
                if monitor.gpuMemoryMB > 0 {
                    HStack {
                        Text("配置記憶體").font(.system(size: 9)).foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f MB", monitor.gpuMemoryMB))
                            .font(.system(size: 9))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Disk

    private var diskSection: some View {
        StatCard(title: "磁碟", icon: "internaldrive") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    NetStat(direction: "arrow.up.circle",  label: "寫入",
                            value: formatSpeed(monitor.diskWriteRate), color: .pink)
                    Divider().frame(height: 36)
                    NetStat(direction: "arrow.down.circle", label: "讀取",
                            value: formatSpeed(monitor.diskReadRate),  color: .teal)
                }
                ForEach(monitor.volumes.prefix(3)) { vol in
                    VolumeRow(vol: vol, ratioColor: ratioColor)
                }
            }
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        StatCard(title: "電池", icon: batteryIcon(monitor.battery)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(monitor.battery.percent)%")
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundColor(batteryColor(monitor.battery))
                    Spacer()
                    Text(batteryStateText(monitor.battery))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ProgressView(value: Double(monitor.battery.percent), total: 100)
                    .tint(batteryColor(monitor.battery))
                HStack(spacing: 12) {
                    if monitor.battery.powerWatts > 0 {
                        MemLabel(color: .yellow, label: "功率",
                                 value: String(format: "%.1f W", monitor.battery.powerWatts))
                    }
                    if monitor.battery.cycleCount > 0 {
                        MemLabel(color: .gray, label: "循環",
                                 value: "\(monitor.battery.cycleCount)")
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Top Process

    private var topProcessSection: some View {
        StatCard(title: "行程排行", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $topMode) {
                    ForEach(TopMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)

                let rows = topMode == .cpu ? monitor.topByCPU : monitor.topByMemory
                if rows.isEmpty {
                    Text("收集中…").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(rows) { row in
                        ProcessRowView(row: row, mode: topMode)
                    }
                }
            }
        }
    }

    // MARK: - AI 額度

    private var tokenUsageSection: some View {
        StatCard(title: "AI 額度", icon: "speedometer") {
            VStack(alignment: .leading, spacing: 10) {
                Text("目前 5 小時視窗剩餘額度")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                CLIUsageRow(usage: tokenMonitor.claude)
                Divider()
                CLIUsageRow(usage: tokenMonitor.codex)
            }
        }
    }

    // MARK: - Helpers

    private func usageColor(_ v: Double, high: Double, mid: Double) -> Color {
        v > high ? .red : v > mid ? .orange : .green
    }

    private func ratioColor(_ r: Double) -> Color {
        r > 0.9 ? .red : r > 0.7 ? .orange : .blue
    }

    private func batteryColor(_ b: BatterySnapshot) -> Color {
        if b.isCharging || b.isPluggedIn { return .green }
        if b.percent <= 10 { return .red }
        if b.percent <= 20 { return .orange }
        return .blue
    }

    private func batteryIcon(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case 0...10:  return "battery.0"
        case 11...35: return "battery.25"
        case 36...60: return "battery.50"
        case 61...85: return "battery.75"
        default:      return "battery.100"
        }
    }

    private func batteryStateText(_ b: BatterySnapshot) -> String {
        if b.isCharging {
            if b.timeToFullMin > 0 { return "充電中 · 剩 \(formatMin(b.timeToFullMin))" }
            if let est = b.estimatedTimeToFullMin { return "充電中 · 約 \(formatMin(est))（估算）" }
            return "充電中"
        }
        if b.isPluggedIn { return "已接電源" }
        if b.timeToEmptyMin > 0 { return "剩 \(formatMin(b.timeToEmptyMin))" }
        if let est = b.estimatedTimeToEmptyMin { return "約 \(formatMin(est))（估算）" }
        return "使用電池"
    }

    private func formatMin(_ m: Int) -> String {
        if m < 60 { return "\(m) 分" }
        return "\(m / 60) 時 \(m % 60) 分"
    }
}

// MARK: - 新增子視圖

struct VolumeRow: View {
    let vol: VolumeUsage
    let ratioColor: (Double) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(vol.id)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(formatBytes(vol.used)) / \(formatBytes(vol.total))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: vol.ratio, total: 1.0)
                .tint(ratioColor(vol.ratio))
                .scaleEffect(x: 1, y: 0.6)
        }
    }
}

struct ProcessRowView: View {
    let row: ProcessRow
    let mode: ContentView.TopMode

    var body: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(valueText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private var valueText: String {
        switch mode {
        case .cpu:    return String(format: "%.1f%%", row.cpuPercent)
        case .memory: return formatBytes(row.residentBytes)
        }
    }
}

/// 單一 AI CLI 的配額列：名稱、剩餘百分比、進度條、重置倒數
struct CLIUsageRow: View {
    let usage: CLIUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(usage.name)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if usage.available {
                    Text("剩 \(Int(usage.remainingPercent.rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(remainColor)
                } else {
                    Text(usage.status)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            if usage.available {
                ProgressView(value: min(usage.usedPercent, 100), total: 100)
                    .tint(remainColor)
                HStack {
                    Text(resetText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let week = usage.weekUsedPercent {
                        Text("本週已用 \(Int(week.rounded()))%")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(usage.status)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 剩餘越少越紅
    private var remainColor: Color {
        let r = usage.remainingPercent
        return r < 15 ? .red : r < 40 ? .orange : .green
    }

    private var resetText: String {
        guard let minutes = usage.minutesToReset else { return "重置時間未知" }
        if minutes <= 0 { return "即將重置" }
        let hours = minutes / 60
        let mins  = minutes % 60
        let dur = hours > 0 ? "\(hours) 時 \(mins) 分" : "\(mins) 分"
        if let reset = usage.resetAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: reset)) 重置 · 還有 \(dur)"
        }
        return "還有 \(dur) 重置"
    }
}

// MARK: - Sub-views

struct StatCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            content
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct CoreBar: View {
    let index: Int
    let usage: Double

    private var barColor: Color {
        usage > 80 ? .red : usage > 50 ? .orange : .green
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(height: geo.size.height * usage / 100)
                }
            }
            .frame(height: 24)
            Text("\(index)")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

struct MemLabel: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8)).foregroundColor(.secondary)
                Text(value).font(.system(size: 9)).monospacedDigit()
            }
        }
    }
}

struct NetStat: View {
    let direction: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: direction).font(.caption).foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                Text(value).font(.caption).monospacedDigit().fontWeight(.medium)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Formatters

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
}

func formatSpeed(_ bps: Double) -> String {
    if bps >= 1_048_576  { return String(format: "%.1f MB/s", bps / 1_048_576) }
    if bps >= 1_024      { return String(format: "%.0f KB/s", bps / 1_024) }
    return String(format: "%.0f B/s", bps)
}
