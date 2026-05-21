import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var tokenMonitor: TokenUsageMonitor
    @ObservedObject var networkMonitor: NetworkInfoMonitor
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
        .frame(width: 360, height: 520)
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
        case .sensors:    sensorsSection
        case .topProcess: topProcessSection
        case .tokenUsage: tokenUsageSection
        case .date:       dateSection
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
                .font(.system(size: 13))
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
            Text("MacPrism")
                .font(.headline)
                .foregroundStyle(theme == .rainbow
                    ? AnyShapeStyle(ColorTheme.prismGradient)
                    : AnyShapeStyle(Color.primary))
            Spacer()
            Button("結束") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.system(size: 13))
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
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", monitor.cpuUsage))
                        .font(.system(size: 13))
                        .foregroundColor(usageColor(monitor.cpuUsage, high: 80, mid: 50))
                        .monospacedDigit()
                }
                MetricBar(value: monitor.cpuUsage / 100,
                          fill: usageFill(monitor.cpuUsage, high: 80, mid: 50))

                Sparkline(values: monitor.cpuHistory,
                          fill: usageFill(monitor.cpuUsage, high: 80, mid: 50),
                          maxValue: 100, unit: "%")
                    .frame(height: 36)

                if !monitor.cpuCores.isEmpty {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(monitor.cpuCores.enumerated()), id: \.offset) { i, usage in
                            CoreBar(index: i + 1, usage: usage, theme: theme)
                        }
                    }
                }

                HStack(spacing: 12) {
                    MemLabel(color: .indigo, label: "負載 1/5/15m", value: loadAvgText)
                    Spacer()
                    MemLabel(color: .gray, label: "開機時間", value: uptimeText)
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
                        .font(.system(size: 13))
                        .monospacedDigit()
                    Text("/")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(formatBytes(monitor.memoryTotal))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(String(format: "%.0f%%", ratio * 100))
                        .font(.system(size: 13))
                        .foregroundColor(ratioColor(ratio))
                        .monospacedDigit()
                }
                MetricBar(value: ratio, fill: ratioFill(ratio))

                Sparkline(values: monitor.memHistory, fill: ratioFill(ratio),
                          maxValue: 100, unit: "%")
                    .frame(height: 36)

                HStack(spacing: 12) {
                    MemLabel(color: .blue,   label: "Active",     value: formatBytes(monitor.memoryActive))
                    MemLabel(color: .orange, label: "Wired",      value: formatBytes(monitor.memoryWired))
                    MemLabel(color: .purple, label: "Compressed", value: formatBytes(monitor.memoryCompressed))
                }

                HStack(spacing: 12) {
                    MemLabel(color: .teal, label: "Swap", value: formatBytes(monitor.swapUsedBytes))
                    MemLabel(color: pressureColor, label: "記憶體壓力", value: pressureLabel)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        StatCard(title: "網路", icon: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    NetStat(direction: "arrow.up", label: "上傳",
                            value: formatSpeed(monitor.networkUpload),
                            color: .orange)
                    Divider().frame(height: 36)
                    NetStat(direction: "arrow.down", label: "下載",
                            value: formatSpeed(monitor.networkDownload),
                            color: .cyan)
                }
                Sparkline(values: monitor.netDownHistory, fill: theme.accentFill(.cyan))
                    .frame(height: 36)

                InfoRow(label: "區域 IP", value: networkMonitor.localIP)
                InfoRow(label: "公開 IP", value: networkMonitor.publicIP)
                if !networkMonitor.ipLocation.isEmpty {
                    InfoRow(label: "位置", value: networkMonitor.ipLocation)
                }

                if !networkMonitor.appTraffic.isEmpty {
                    Divider()
                    Text("App 流量")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(networkMonitor.appTraffic) { row in
                        HStack {
                            Text(row.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("↓\(formatBytes(row.bytesIn))  ↑\(formatBytes(row.bytesOut))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if !networkMonitor.connections.isEmpty {
                    Divider()
                    Text("目前連線（\(networkMonitor.connections.count)）")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(networkMonitor.connections.prefix(6)) { conn in
                        HStack {
                            Text(conn.command)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Text(conn.remote)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    // MARK: - GPU

    private var gpuSection: some View {
        StatCard(title: "GPU", icon: "display") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("使用率").font(.system(size: 13)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", monitor.gpuUsage))
                        .font(.system(size: 13))
                        .foregroundColor(usageColor(monitor.gpuUsage, high: 80, mid: 50))
                        .monospacedDigit()
                }
                MetricBar(value: min(monitor.gpuUsage, 100) / 100,
                          fill: usageFill(monitor.gpuUsage, high: 80, mid: 50))
                Sparkline(values: monitor.gpuHistory,
                          fill: usageFill(monitor.gpuUsage, high: 80, mid: 50),
                          maxValue: 100, unit: "%")
                    .frame(height: 36)
                if monitor.gpuMemoryMB > 0 {
                    HStack {
                        Text("配置記憶體").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f MB", monitor.gpuMemoryMB))
                            .font(.system(size: 11))
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
                    VolumeRow(vol: vol, theme: theme)
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
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                MetricBar(value: Double(monitor.battery.percent) / 100,
                          fill: batteryFill(monitor.battery))
                HStack(spacing: 12) {
                    if monitor.battery.powerWatts > 0 {
                        MemLabel(color: .yellow, label: "功率",
                                 value: String(format: "%.1f W", monitor.battery.powerWatts))
                    }
                    if monitor.battery.cycleCount > 0 {
                        MemLabel(color: .gray, label: "循環",
                                 value: "\(monitor.battery.cycleCount)")
                    }
                    if monitor.battery.healthPercent > 0 {
                        MemLabel(color: healthColor(monitor.battery.healthPercent),
                                 label: "健康度",
                                 value: "\(monitor.battery.healthPercent)%")
                    }
                    Spacer()
                }

                if !monitor.btDevices.isEmpty {
                    Divider()
                    ForEach(monitor.btDevices) { dev in
                        HStack(spacing: 6) {
                            Image(systemName: "wave.3.right.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                            Text(dev.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(dev.percent)%")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundColor(dev.percent <= 20 ? .red : .secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 感測器

    private var sensorsSection: some View {
        StatCard(title: "感測器", icon: "thermometer") {
            VStack(alignment: .leading, spacing: 6) {
                if monitor.temperatures.isEmpty && monitor.fans.isEmpty {
                    Text("無法讀取感測器資料")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    if let maxT = monitor.maxTemperature {
                        HStack {
                            Text("最高溫度")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.0f°C", maxT))
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .foregroundColor(tempColor(maxT))
                        }
                    }
                    ForEach(monitor.temperatures.prefix(6)) { temp in
                        HStack {
                            Text(temp.name)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(String(format: "%.0f°C", temp.celsius))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(tempColor(temp.celsius))
                        }
                    }
                    if monitor.fans.isEmpty {
                        Text("此機型無風扇")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Divider()
                        ForEach(monitor.fans) { fan in
                            HStack(spacing: 6) {
                                Image(systemName: "fanblades")
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentColor)
                                Text("風扇 \(fan.id + 1)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(fan.rpm) RPM")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 日期

    private var dateSection: some View {
        StatCard(title: "日期", icon: "calendar") {
            VStack(alignment: .leading, spacing: 8) {
                let now = Date()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fullDateString(now))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(weekdayString(now))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                MonthCalendarView(date: now)
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
                    Text("收集中…").font(.system(size: 13)).foregroundColor(.secondary)
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
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                CLIUsageRow(usage: tokenMonitor.claude, theme: theme)
                Divider()
                CLIUsageRow(usage: tokenMonitor.codex, theme: theme)
            }
        }
    }

    // MARK: - Helpers

    private var theme: ColorTheme { settings.colorTheme }

    private func usageColor(_ v: Double, high: Double, mid: Double) -> Color {
        theme.color(usageSeverity(v, high: high, mid: mid))
    }
    private func usageFill(_ v: Double, high: Double, mid: Double) -> AnyShapeStyle {
        theme.fill(usageSeverity(v, high: high, mid: mid))
    }

    private func ratioColor(_ r: Double) -> Color { theme.color(ratioSeverity(r)) }
    private func ratioFill(_ r: Double) -> AnyShapeStyle { theme.fill(ratioSeverity(r)) }

    private func batterySeverity(_ b: BatterySnapshot) -> Severity {
        if b.percent <= 10 { return .high }
        if b.percent <= 20 { return .warn }
        return .ok
    }
    private func batteryColor(_ b: BatterySnapshot) -> Color { theme.color(batterySeverity(b)) }
    private func batteryFill(_ b: BatterySnapshot) -> AnyShapeStyle { theme.fill(batterySeverity(b)) }

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

    // MARK: - 感測器 / 系統輔助

    private func tempColor(_ celsius: Double) -> Color {
        theme.color(celsius >= 85 ? .high : celsius >= 70 ? .warn : .ok)
    }

    private func healthColor(_ percent: Int) -> Color {
        theme.color(percent < 80 ? .warn : .ok)
    }

    private var loadAvgText: String {
        guard monitor.loadAverage.count == 3 else { return "—" }
        return monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    private var uptimeText: String {
        let total = Int(monitor.uptimeSeconds)
        guard total > 0 else { return "—" }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 時" }
        if hours > 0 { return "\(hours) 時 \(mins) 分" }
        return "\(mins) 分"
    }

    private var pressureLabel: String {
        switch monitor.memoryPressureLevel {
        case 4:  return "危急"
        case 2:  return "警告"
        default: return "正常"
        }
    }

    private var pressureColor: Color {
        switch monitor.memoryPressureLevel {
        case 4:  return theme.color(.high)
        case 2:  return theme.color(.warn)
        default: return theme.color(.ok)
        }
    }
}

// MARK: - 新增子視圖

struct VolumeRow: View {
    let vol: VolumeUsage
    let theme: ColorTheme

    var body: some View {
        HStack(spacing: 10) {
            DonutRing(ratio: vol.ratio, fill: theme.fill(ratioSeverity(vol.ratio)))
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(vol.name.isEmpty ? vol.id : vol.name)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("已用 \(formatBytes(vol.used))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text("共 \(formatBytes(vol.total))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// 甜甜圈圓環，中央顯示百分比
struct DonutRing: View {
    let ratio: Double
    let fill: AnyShapeStyle

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(ratio, 0), 1)))
                .stroke(fill, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}

struct ProcessRowView: View {
    let row: ProcessRow
    let mode: ContentView.TopMode

    var body: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(valueText)
                .font(.system(size: 12))
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
    let theme: ColorTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(usage.name)
                    .font(.system(size: 13))
                    .fontWeight(.medium)
                Spacer()
                if usage.available {
                    Text("剩 \(Int(usage.remainingPercent.rounded()))%")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundColor(remainColor)
                } else {
                    Text(usage.status)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            if usage.available {
                MetricBar(value: min(usage.usedPercent, 100) / 100, fill: remainFill)
                HStack {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let week = usage.weekUsedPercent {
                        Text("本週已用 \(Int(week.rounded()))%")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(usage.status)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 剩餘越少越嚴重
    private var remainSeverity: Severity {
        let r = usage.remainingPercent
        return r < 15 ? .high : r < 40 ? .warn : .ok
    }
    private var remainColor: Color { theme.color(remainSeverity) }
    private var remainFill: AnyShapeStyle { theme.fill(remainSeverity) }

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

/// 當月月曆，今天以強調色標示
struct MonthCalendarView: View {
    let date: Date
    private let cal = Calendar.current
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        let cells = monthCells()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day = day {
                        Text("\(day)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 16)
                            .background(isToday(day) ? Color.accentColor : Color.clear)
                            .foregroundColor(isToday(day) ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Text("").frame(maxWidth: .infinity, minHeight: 16)
                    }
                }
            }
        }
    }

    /// 回傳當月各格：前導空白為 nil，其餘為日期數字
    private func monthCells() -> [Int?] {
        guard let range = cal.range(of: .day, in: .month, for: date),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: date))
        else { return [] }
        let leading = cal.component(.weekday, from: first) - 1   // 週日 = 1
        var cells = [Int?](repeating: nil, count: leading)
        cells.append(contentsOf: range.map { Optional($0) })
        return cells
    }

    private func isToday(_ day: Int) -> Bool {
        cal.component(.day, from: date) == day
    }
}

// MARK: - 嚴重程度判定

func usageSeverity(_ v: Double, high: Double, mid: Double) -> Severity {
    v > high ? .high : v > mid ? .warn : .ok
}

func ratioSeverity(_ r: Double) -> Severity {
    r > 0.9 ? .high : r > 0.7 ? .warn : .ok
}

/// 進度條 —— 支援純色或彩虹漸層填色
struct MetricBar: View {
    let value: Double            // 0...1
    let fill: AnyShapeStyle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(fill)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// 迷你走勢圖（折線）—— 含格線與 Y 軸刻度
struct Sparkline: View {
    let values: [Double]
    let fill: AnyShapeStyle
    var maxValue: Double? = nil   // nil = 依資料自動縮放（網路）；給值 = 固定上限（CPU/GPU 100）
    var unit: String = ""

    /// 縱軸上限
    private var scaleMax: Double {
        if let m = maxValue { return m }
        return max(values.max() ?? 1, 0.0001)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Y 軸刻度：上限 / 中點 / 0
            VStack(alignment: .trailing) {
                Text(axisLabel(scaleMax))
                Spacer()
                Text(axisLabel(scaleMax / 2))
                Spacer()
                Text(axisLabel(0))
            }
            .font(.system(size: 8))
            .foregroundColor(.secondary)
            .monospacedDigit()
            .frame(width: 32)

            // 格線 + 折線
            GeometryReader { geo in
                ZStack {
                    Path { p in
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = geo.size.height * CGFloat(fraction)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(Color.primary.opacity(0.13), lineWidth: 0.5)

                    if values.count > 1 {
                        Path { path in
                            for (i, v) in values.enumerated() {
                                let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                                let y = geo.size.height * (1 - CGFloat(min(v / scaleMax, 1)))
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else      { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(fill, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
            }
        }
    }

    /// 縱軸刻度文字：固定上限 → 百分比；自動縮放 → 精簡速率
    private func axisLabel(_ value: Double) -> String {
        if maxValue != nil { return "\(Int(value))\(unit)" }
        if value >= 1_048_576 { return String(format: "%.0fM", value / 1_048_576) }
        if value >= 1_024     { return String(format: "%.0fK", value / 1_024) }
        return "0"
    }
}

/// 標籤 + 數值的小列
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 13))
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
    let theme: ColorTheme

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.fill(usageSeverity(usage, high: 80, mid: 50)))
                        .frame(height: geo.size.height * usage / 100)
                }
            }
            .frame(height: 24)
            Text("\(index)")
                .font(.system(size: 10))
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
                Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                Text(value).font(.system(size: 11)).monospacedDigit()
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
            Image(systemName: direction).font(.system(size: 13)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                Text(value).font(.system(size: 13)).monospacedDigit().fontWeight(.medium)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Formatters

private let zhTW = Locale(identifier: "zh_Hant_TW")

func fullDateString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = zhTW
    f.dateFormat = "yyyy 年 M 月 d 日"
    return f.string(from: d)
}

func weekdayString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = zhTW
    f.dateFormat = "EEEE"
    return f.string(from: d)
}

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
