import Foundation
import SwiftUI

enum StatItem: String, CaseIterable, Identifiable {
    case cpu, memory, network, gpu, disk, battery, topProcess

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu:        return "CPU"
        case .memory:     return "記憶體"
        case .network:    return "網路"
        case .gpu:        return "GPU"
        case .disk:       return "磁碟"
        case .battery:    return "電池"
        case .topProcess: return "行程排行"
        }
    }

    var icon: String {
        switch self {
        case .cpu:        return "cpu"
        case .memory:     return "memorychip"
        case .network:    return "network"
        case .gpu:        return "display"
        case .disk:       return "internaldrive"
        case .battery:    return "battery.100"
        case .topProcess: return "list.bullet.rectangle"
        }
    }

    /// 不適合放 menu bar 的項目（資料量太大）
    var canShowInMenuBar: Bool { self != .topProcess }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var menuBarItems: Set<StatItem> {
        didSet { save(menuBarItems, key: Keys.menuBar) }
    }
    @Published var panelItems: Set<StatItem> {
        didSet { save(panelItems, key: Keys.panel) }
    }

    private enum Keys {
        static let menuBar = "openstat.settings.menuBarItems"
        static let panel   = "openstat.settings.panelItems"
    }

    /// 預設：menu bar 顯示 CPU / 記憶體 / 網路 / 電池；面板顯示全部
    private static let defaultMenuBar: Set<StatItem> = [.cpu, .memory, .network, .battery]
    private static let defaultPanel:   Set<StatItem> = Set(StatItem.allCases)

    private init() {
        self.menuBarItems = AppSettings.load(key: Keys.menuBar, fallback: AppSettings.defaultMenuBar)
        self.panelItems   = AppSettings.load(key: Keys.panel,   fallback: AppSettings.defaultPanel)
    }

    func toggleMenuBar(_ item: StatItem) {
        if menuBarItems.contains(item) { menuBarItems.remove(item) }
        else                            { menuBarItems.insert(item) }
    }

    func togglePanel(_ item: StatItem) {
        if panelItems.contains(item) { panelItems.remove(item) }
        else                          { panelItems.insert(item) }
    }

    func resetToDefaults() {
        menuBarItems = AppSettings.defaultMenuBar
        panelItems   = AppSettings.defaultPanel
    }

    // MARK: - Persistence

    private func save(_ set: Set<StatItem>, key: String) {
        UserDefaults.standard.set(set.map(\.rawValue), forKey: key)
    }

    private static func load(key: String, fallback: Set<StatItem>) -> Set<StatItem> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return fallback
        }
        return Set(raw.compactMap(StatItem.init(rawValue:)))
    }
}
