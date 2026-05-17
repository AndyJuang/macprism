import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            panelTab
                .tabItem { Label("下拉面板", systemImage: "rectangle.expand.vertical") }
        }
        .frame(width: 380, height: 360)
        .padding()
    }

    private var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("勾選要顯示在 menu bar 的指標")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(StatItem.allCases.filter(\.canShowInMenuBar)) { item in
                Toggle(isOn: binding(for: item, in: \.menuBarItems)) {
                    Label(item.label, systemImage: item.icon)
                }
                .toggleStyle(.checkbox)
            }

            Spacer()
            footer
        }
    }

    private var panelTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("勾選要顯示在下拉面板的區塊")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(StatItem.allCases) { item in
                Toggle(isOn: binding(for: item, in: \.panelItems)) {
                    Label(item.label, systemImage: item.icon)
                }
                .toggleStyle(.checkbox)
            }

            Spacer()
            footer
        }
    }

    private var footer: some View {
        HStack {
            Button("恢復預設值") { settings.resetToDefaults() }
            Spacer()
            Text("變更會即時套用")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func binding(for item: StatItem,
                         in keyPath: ReferenceWritableKeyPath<AppSettings, Set<StatItem>>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath].contains(item) },
            set: { isOn in
                var s = settings[keyPath: keyPath]
                if isOn { s.insert(item) } else { s.remove(item) }
                settings[keyPath: keyPath] = s
            }
        )
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init(settings: AppSettings) {
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: host)
        window.title = "OpenStat 設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 380, height: 360))
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
