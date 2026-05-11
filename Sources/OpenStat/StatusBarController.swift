import AppKit
import SwiftUI
import ServiceManagement

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let monitor: SystemMonitor
    private var timer: Timer?
    private var eventMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover    = NSPopover()
        monitor    = SystemMonitor()
        super.init()

        setupButton()
        setupPopover()
        startMonitoring()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.font      = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        button.alignment = .center
        // 同時接收左鍵與右鍵事件
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick)
        button.target = self
    }

    private func setupPopover() {
        let content = NSHostingController(rootView: ContentView(monitor: monitor))
        content.view.frame = NSRect(x: 0, y: 0, width: 300, height: 360)

        popover.contentViewController = content
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.behavior    = .transient
        popover.animates    = true
    }

    private func startMonitoring() {
        monitor.update()
        refreshStatusBar()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.monitor.update()
            self?.refreshStatusBar()
        }
    }

    private func refreshStatusBar() {
        let cpu = String(format: "%3.0f%%", monitor.cpuUsage)
        let mem = shortBytes(monitor.memoryUsed)
        let up  = shortSpeed(monitor.networkUpload)
        let dn  = shortSpeed(monitor.networkDownload)
        statusItem.button?.title = "\(cpu) \(mem) ↑\(up) ↓\(dn)"
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

        let loginTitle = "登入時自動啟動"
        let loginItem  = NSMenuItem(title: loginTitle, action: #selector(toggleLoginItem), keyEquivalent: "")
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
        // 還原 nil，讓左鍵繼續顯示 popover
        statusItem.menu = nil
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

    // 4 字元：" 8G" / "32G" / "512M"
    private func shortBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%3.0fG", gb) }
        return String(format: "%3.0fM", Double(bytes) / 1_048_576)
    }

    // 4 字元：" 1M" / "512K" / "  0B"
    private func shortSpeed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%3.0fM", bps / 1_048_576) }
        if bps >= 1_024     { return String(format: "%3.0fK", bps / 1_024) }
        return String(format: "%3.0fB", bps)
    }
}
