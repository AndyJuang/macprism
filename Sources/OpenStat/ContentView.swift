import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    cpuSection
                    memorySection
                    networkSection
                }
                .padding(12)
            }
        }
        .frame(width: 300)
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

    // MARK: - Helpers

    private func usageColor(_ v: Double, high: Double, mid: Double) -> Color {
        v > high ? .red : v > mid ? .orange : .green
    }

    private func ratioColor(_ r: Double) -> Color {
        r > 0.9 ? .red : r > 0.7 ? .orange : .blue
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
