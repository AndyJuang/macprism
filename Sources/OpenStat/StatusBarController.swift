import AppKit
import SwiftUI
import ServiceManagement
import Combine

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let monitor: SystemMonitor
    private let tokenMonitor = TokenUsageMonitor()
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var tokenTimer: Timer?
    private var eventMonitor: Any?
    private var settingsWindow: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover    = NSPopover()
        monitor    = SystemMonitor()
        super.init()

        setupButton()
        setupPopover()
        startMonitoring()
        observeSettings()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.font      = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        button.alignment = .center
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick)
        button.target = self
    }

    private func setupPopover() {
        let content = NSHostingController(rootView: ContentView(monitor: monitor, tokenMonitor: tokenMonitor, settings: settings))
        content.view.frame = NSRect(x: 0, y: 0, width: 320, height: 520)

        popover.contentViewController = content
        popover.contentSize = NSSize(width: 320, height: 520)
        popover.behavior    = .transient
        popover.animates    = true
    }

    private func startMonitoring() {
        monitor.update()
        tokenMonitor.refresh(force: true)
        refreshStatusBar()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.monitor.update()
            self?.refreshStatusBar()
        }

        // AI 額度更新較慢，獨立用 60 秒節奏刷新（Claude API 內部再節流到 5 分鐘）
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tokenMonitor.refresh()
            self?.refreshStatusBar()
        }
    }

    /// 設定改動時即時刷新 menu bar
    private func observeSettings() {
        settings.$menuBarItems
            .dropFirst()
            .sink { [weak self] _ in self?.refreshStatusBar() }
            .store(in: &cancellables)

        settings.$tokenMenuBarSource
            .dropFirst()
            .sink { [weak self] _ in self?.refreshStatusBar() }
            .store(in: &cancellables)
    }

    private func refreshStatusBar() {
        let items = settings.menuBarItems
        var parts: [String] = []

        if items.contains(.cpu) {
            parts.append(String(format: "%3.0f%%", monitor.cpuUsage))
        }
        if items.contains(.gpu) && monitor.gpuAvailable {
            parts.append("G" + String(format: "%2.0f%%", monitor.gpuUsage))
        }
        if items.contains(.memory) {
            parts.append(shortBytes(monitor.memoryUsed))
        }
        if items.contains(.disk) {
            parts.append("D↑\(shortSpeed(monitor.diskWriteRate))")
            parts.append("D↓\(shortSpeed(monitor.diskReadRate))")
        }
        if items.contains(.network) {
            parts.append("↑\(shortSpeed(monitor.networkUpload))")
            parts.append("↓\(shortSpeed(monitor.networkDownload))")
        }
        if items.contains(.battery) && monitor.battery.present {
            parts.append("\(monitor.battery.percent)%" + (monitor.battery.isCharging ? "⚡" : ""))
        }
        if items.contains(.sensors), let temp = monitor.maxTemperature {
            parts.append(String(format: "%.0f°", temp))
        }
        if items.contains(.tokenUsage),
           let text = tokenMonitor.menuBarText(for: settings.tokenMenuBarSource) {
            parts.append(text)
        }
        if items.contains(.date) {
            parts.append(menuBarDateString())
        }

        // 全部關閉時退回顯示圖示，避免 menu bar 變空白
        if parts.isEmpty {
            statusItem.button?.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "OpenStat")
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = parts.joined(separator: " ")
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            if popover.isShown { closePopover() } else { openPopover(sender) }
        }
    }

    private func openPopover(_ sender: NSStatusBarButton) {
        tokenMonitor.refresh()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    // MARK: - 右鍵選單

    private func showContextMenu() {
        let menu = NSMenu()

        let prefs = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "登入時自動啟動", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state  = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 OpenStat", action: #selector(quit), keyEquivalent: "q")

        menu.delegate  = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings)
        }
        settingsWindow?.show()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText    = "無法變更登入項目"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // 4 字元
    private func shortBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%3.0fG", gb) }
        return String(format: "%3.0fM", Double(bytes) / 1_048_576)
    }

    private func shortSpeed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%3.0fM", bps / 1_048_576) }
        if bps >= 1_024     { return String(format: "%3.0fK", bps / 1_024) }
        return String(format: "%3.0fB", bps)
    }

    private func menuBarDateString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d EEE"
        return f.string(from: Date())
    }
}
