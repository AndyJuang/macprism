import Foundation
import SwiftUI

enum StatItem: String, CaseIterable, Identifiable {
    case cpu, memory, network, gpu, disk, battery, sensors, topProcess, tokenUsage, date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu:        return "CPU"
        case .memory:     return "記憶體"
        case .network:    return "網路"
        case .gpu:        return "GPU"
        case .disk:       return "磁碟"
        case .battery:    return "電池"
        case .sensors:    return "感測器"
        case .topProcess: return "行程排行"
        case .tokenUsage: return "AI 額度"
        case .date:       return "日期"
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
        case .sensors:    return "thermometer"
        case .topProcess: return "list.bullet.rectangle"
        case .tokenUsage: return "speedometer"
        case .date:       return "calendar"
        }
    }

    /// 不適合放 menu bar 的項目（資料量太大）
    var canShowInMenuBar: Bool { self != .topProcess }
}

/// menu bar 的「AI 額度」要顯示哪一個 CLI 的剩餘額度
enum TokenMenuBarSource: String, CaseIterable, Identifiable {
    case lowest, claude, codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowest: return "兩者取較低"
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }
}

/// 嚴重程度 —— 決定配色
enum Severity { case ok, warn, high }

/// 下拉面板配色主題
enum ColorTheme: String, CaseIterable, Identifiable {
    case standard, accessible, rainbow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:   return "標準"
        case .accessible: return "色弱友善"
        case .rainbow:    return "彩虹"
        }
    }

    /// 稜鏡彩虹漸層
    static let prismGradient = LinearGradient(
        colors: [
            Color(red: 0.973, green: 0.443, blue: 0.443),
            Color(red: 0.984, green: 0.749, blue: 0.141),
            Color(red: 0.204, green: 0.827, blue: 0.600),
            Color(red: 0.220, green: 0.741, blue: 0.973),
            Color(red: 0.506, green: 0.549, blue: 0.973),
        ],
        startPoint: .leading, endPoint: .trailing
    )

    /// 嚴重程度 → 單色（文字、小圖示用）
    func color(_ s: Severity) -> Color {
        switch self {
        case .standard:
            switch s {
            case .ok:   return .green
            case .warn: return .orange
            case .high: return .red
            }
        case .accessible, .rainbow:
            // 色弱友善：避開紅綠對比，改用藍／琥珀／紅，亮度也有明顯落差
            switch s {
            case .ok:   return Color(red: 0.16, green: 0.55, blue: 0.98)
            case .warn: return Color(red: 0.95, green: 0.61, blue: 0.07)
            case .high: return Color(red: 0.90, green: 0.16, blue: 0.22)
            }
        }
    }

    /// 嚴重程度 → 填色（進度條／走勢圖／圓環；彩虹模式回傳漸層）
    func fill(_ s: Severity) -> AnyShapeStyle {
        self == .rainbow ? AnyShapeStyle(ColorTheme.prismGradient) : AnyShapeStyle(color(s))
    }

    /// 裝飾色填色：彩虹模式統一漸層，其餘維持原色
    func accentFill(_ c: Color) -> AnyShapeStyle {
        self == .rainbow ? AnyShapeStyle(ColorTheme.prismGradient) : AnyShapeStyle(c)
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var menuBarItems: Set<StatItem> {
        didSet { saveSet(menuBarItems, key: Keys.menuBar) }
    }

    /// 下拉面板的「順序 + 啟用清單」：陣列中存在 = 顯示；不在 = 不顯示。
    /// 用 `panelEnabled` 過濾才是真正會渲染的項目。
    @Published var panelOrder: [StatItem] {
        didSet { saveArray(panelOrder, key: Keys.panelOrder) }
    }
    @Published var panelEnabled: Set<StatItem> {
        didSet { saveSet(panelEnabled, key: Keys.panelEnabled) }
    }

    /// menu bar 的「AI 額度」顯示來源
    @Published var tokenMenuBarSource: TokenMenuBarSource {
        didSet { UserDefaults.standard.set(tokenMenuBarSource.rawValue, forKey: Keys.tokenSource) }
    }

    /// menu bar 是否顯示 CPU 走勢小圖
    @Published var menuBarShowGraph: Bool {
        didSet { UserDefaults.standard.set(menuBarShowGraph, forKey: Keys.menuBarGraph) }
    }

    /// 下拉面板配色主題
    @Published var colorTheme: ColorTheme {
        didSet { UserDefaults.standard.set(colorTheme.rawValue, forKey: Keys.colorTheme) }
    }

    private enum Keys {
        static let menuBar      = "macprism.settings.menuBarItems"
        static let panelOrder   = "macprism.settings.panelOrder"
        static let panelEnabled = "macprism.settings.panelEnabled"
        static let legacyPanel  = "macprism.settings.panelItems"  // 舊版鍵
        static let tokenSource  = "macprism.settings.tokenMenuBarSource"
        static let menuBarGraph = "macprism.settings.menuBarShowGraph"
        static let colorTheme   = "macprism.settings.colorTheme"
    }

    /// 預設：menu bar 顯示 CPU / 記憶體 / 網路 / 電池；面板依 allCases 順序、全部啟用
    private static let defaultMenuBar: Set<StatItem> = [.cpu, .memory, .network, .battery]
    private static let defaultPanelOrder: [StatItem] = StatItem.allCases
    private static let defaultPanelEnabled: Set<StatItem> = Set(StatItem.allCases)

    private init() {
        self.menuBarItems = AppSettings.loadSet(key: Keys.menuBar, fallback: AppSettings.defaultMenuBar)

        let (order, enabled) = AppSettings.loadPanel()
        self.panelOrder   = order
        self.panelEnabled = enabled

        let rawSource = UserDefaults.standard.string(forKey: Keys.tokenSource) ?? ""
        self.tokenMenuBarSource = TokenMenuBarSource(rawValue: rawSource) ?? .lowest

        self.menuBarShowGraph = UserDefaults.standard.bool(forKey: Keys.menuBarGraph)

        let rawTheme = UserDefaults.standard.string(forKey: Keys.colorTheme) ?? ""
        self.colorTheme = ColorTheme(rawValue: rawTheme) ?? .standard
    }

    func toggleMenuBar(_ item: StatItem) {
        if menuBarItems.contains(item) { menuBarItems.remove(item) }
        else                            { menuBarItems.insert(item) }
    }

    func togglePanel(_ item: StatItem) {
        if panelEnabled.contains(item) { panelEnabled.remove(item) }
        else                            { panelEnabled.insert(item) }
    }

    func movePanelItem(from source: IndexSet, to destination: Int) {
        panelOrder.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        menuBarItems       = AppSettings.defaultMenuBar
        panelOrder         = AppSettings.defaultPanelOrder
        panelEnabled       = AppSettings.defaultPanelEnabled
        tokenMenuBarSource = .lowest
        menuBarShowGraph   = false
        colorTheme         = .standard
    }

    // MARK: - Persistence

    private func saveSet(_ set: Set<StatItem>, key: String) {
        UserDefaults.standard.set(set.map(\.rawValue), forKey: key)
    }

    private func saveArray(_ arr: [StatItem], key: String) {
        UserDefaults.standard.set(arr.map(\.rawValue), forKey: key)
    }

    private static func loadSet(key: String, fallback: Set<StatItem>) -> Set<StatItem> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return fallback
        }
        return Set(raw.compactMap(StatItem.init(rawValue:)))
    }

    /// 載入面板順序 + 啟用集合，含舊版 `panelItems` 遷移
    private static func loadPanel() -> (order: [StatItem], enabled: Set<StatItem>) {
        let defaults = UserDefaults.standard

        // 1. 新版鍵存在 → 直接讀
        if let orderRaw = defaults.array(forKey: Keys.panelOrder) as? [String] {
            var order = orderRaw.compactMap(StatItem.init(rawValue:))
            var enabled = loadSet(key: Keys.panelEnabled, fallback: defaultPanelEnabled)
            // 補上新增加的 StatItem case（未來新增功能時不會消失，且預設啟用）
            for item in StatItem.allCases where !order.contains(item) {
                order.append(item)
                enabled.insert(item)
            }
            return (order, enabled)
        }

        // 2. 舊版鍵存在 → 遷移：order 用 allCases，enabled = 舊 set
        if let legacyRaw = defaults.array(forKey: Keys.legacyPanel) as? [String] {
            let legacy = Set(legacyRaw.compactMap(StatItem.init(rawValue:)))
            return (defaultPanelOrder, legacy)
        }

        // 3. 全新安裝
        return (defaultPanelOrder, defaultPanelEnabled)
    }
}
