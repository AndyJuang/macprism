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
        .frame(width: 380, height: 420)
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

            Divider()

            HStack {
                Label("AI 額度顯示", systemImage: "speedometer")
                Spacer()
                Picker("", selection: $settings.tokenMenuBarSource) {
                    ForEach(TokenMenuBarSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(!settings.menuBarItems.contains(.tokenUsage))
            }

            Toggle(isOn: $settings.menuBarShowGraph) {
                Label("顯示 CPU 走勢小圖", systemImage: "chart.xyaxis.line")
            }
            .toggleStyle(.checkbox)

            Spacer()
            footer
        }
    }

    private var panelTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拖曳調整順序,勾選控制顯示")
                .font(.subheadline)
                .foregroundColor(.secondary)

            List {
                ForEach(settings.panelOrder, id: \.self) { item in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                        Toggle(isOn: panelEnabledBinding(for: item)) {
                            Label(item.label, systemImage: item.icon)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .onMove { source, destination in
                    settings.movePanelItem(from: source, to: destination)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            HStack {
                Label("配色", systemImage: "paintpalette")
                Spacer()
                Picker("", selection: $settings.colorTheme) {
                    ForEach(ColorTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            footer
        }
    }

    private func panelEnabledBinding(for item: StatItem) -> Binding<Bool> {
        Binding(
            get: { settings.panelEnabled.contains(item) },
            set: { isOn in
                var s = settings.panelEnabled
                if isOn { s.insert(item) } else { s.remove(item) }
                settings.panelEnabled = s
            }
        )
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
        window.title = "MacPrism 設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
