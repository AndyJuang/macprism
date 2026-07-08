import Foundation
import Security

/// 單一 AI CLI 的配額快照（聚焦「目前 5 小時滾動視窗」）
struct CLIUsage {
    let name: String                     // "Claude Code" / "Codex"
    var available: Bool = false          // 是否成功取得資料
    var usedPercent: Double = 0          // 5 小時視窗已用百分比
    var resetAt: Date? = nil             // 5 小時視窗重置時間點
    var weekUsedPercent: Double? = nil   // 每週視窗已用百分比
    var weekResetAt: Date? = nil         // 每週視窗重置時間點
    var status: String = "讀取中…"        // 顯示用狀態 / 錯誤訊息

    /// 5 小時視窗剩餘百分比
    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// 每週視窗剩餘百分比；nil 表示無週配額資料
    var weekRemainingPercent: Double? {
        guard let used = weekUsedPercent else { return nil }
        return max(0, 100 - used)
    }

    /// 距離重置還有幾分鐘；nil = 未知，0 = 即將重置
    var minutesToReset: Int? {
        guard let r = resetAt else { return nil }
        let secs = r.timeIntervalSinceNow
        return secs > 0 ? Int((secs / 60).rounded()) : 0
    }

    /// 距離週重置還有幾分鐘；nil = 未知，0 = 即將重置
    var minutesToWeekReset: Int? {
        guard let r = weekResetAt else { return nil }
        let secs = r.timeIntervalSinceNow
        return secs > 0 ? Int((secs / 60).rounded()) : 0
    }
}

/// 讀取 Claude Code 與 Codex 的本機配額狀況。
/// - Codex：完全離線，讀最新 rollout 檔內建的 rate-limit 快照。
/// - Claude：優先讀 statusline.sh 擷取寫出的 `~/.claude/usage-status.json`；
///   缺檔或過期才退回呼叫 `api.anthropic.com/api/oauth/usage`（憑證取自 Keychain）。
final class TokenUsageMonitor: ObservableObject {
    @Published var claude = CLIUsage(name: "Claude Code")
    @Published var codex  = CLIUsage(name: "Codex")

    /// 任一 CLI 有資料
    var hasData: Bool { claude.available || codex.available }

    /// 兩者中「剩餘最少」的百分比 — 供 menu bar 一眼示警
    var lowestRemaining: Double? {
        [claude, codex].filter(\.available).map(\.remainingPercent).min()
    }

    /// 依設定產生 menu bar 的「AI 額度」字串；該來源無資料時回 nil
    func menuBarText(for source: TokenMenuBarSource) -> String? {
        switch source {
        case .lowest:
            guard let remaining = lowestRemaining else { return nil }
            return "AI" + String(format: "%3.0f%%", remaining)
        case .claude:
            guard claude.available else { return nil }
            return "CC" + String(format: "%3.0f%%", claude.remainingPercent)
        case .codex:
            guard codex.available else { return nil }
            return "CX" + String(format: "%3.0f%%", codex.remainingPercent)
        }
    }

    private var lastClaudeFetch: Date = .distantPast
    private let claudeInterval: TimeInterval = 300   // Claude API 最多 5 分鐘一次
    /// 使用者按過「拒絕」鑰匙圈授權後設為 true，本次啟動不再嘗試讀鑰匙圈，避免一直跳窗。
    /// （menu bar 的額度仍可由本機快照檔顯示，不受影響）
    private var claudeKeychainDenied = false

    /// 觸發刷新。Codex 永遠重讀本機檔；Claude 先讀本機快照，缺檔才打 API（5 分鐘節流）。
    func refresh(force: Bool = false) {
        Task {
            let result = await Self.readCodexUsage()
            await MainActor.run { self.codex = result }
        }
        Task {
            // 1) 優先讀 statusLine hook 寫出的本機快照（便宜，每次都試）
            if let local = Self.readClaudeUsageFromFile() {
                await MainActor.run { self.claude = local }
                return
            }
            // 2) 缺檔或過期 → 退回呼叫官方 API，但節流至 5 分鐘一次
            //    且本次啟動曾被拒絕鑰匙圈授權時直接略過，不再跳窗
            let shouldCallAPI = await MainActor.run { () -> Bool in
                if self.claudeKeychainDenied { return false }
                if force || Date().timeIntervalSince(self.lastClaudeFetch) >= self.claudeInterval {
                    self.lastClaudeFetch = Date()
                    return true
                }
                return false
            }
            guard shouldCallAPI else { return }
            let (result, denied) = await Self.fetchClaudeUsageFromAPI()
            await MainActor.run {
                self.claude = result
                if denied { self.claudeKeychainDenied = true }
            }
        }
    }

    // MARK: - Claude — 本機快照（statusline.sh 擷取寫出）

    /// 讀取 `~/.claude/usage-status.json`。回傳 nil 表示缺檔 / 無法解析 / 已過期，
    /// 呼叫端應退回 API。檔案由 statusline.sh 把 statusLine 的 `rate_limits` 擷取寫出。
    private static func readClaudeUsageFromFile() -> CLIUsage? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage-status.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = obj["rate_limits"] as? [String: Any],
              let fiveHour = rateLimits["five_hour"] as? [String: Any]
        else { return nil }

        // 擷取時間超過 6 小時（已跨過一個完整 5 小時視窗）視為過期 → 改打 API
        let capturedAt = parseISO(obj["captured_at"] as? String)
        if let captured = capturedAt, Date().timeIntervalSince(captured) > 6 * 3600 {
            return nil
        }

        var u = CLIUsage(name: "Claude Code")
        u.usedPercent = num(fiveHour["used_percentage"]) ?? num(fiveHour["utilization"]) ?? 0
        u.resetAt = parseReset(fiveHour["resets_at"])
        if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
            u.weekUsedPercent = num(sevenDay["used_percentage"]) ?? num(sevenDay["utilization"])
            u.weekResetAt = parseReset(sevenDay["resets_at"])
        }
        u.available = true
        u.status = capturedAt.map { "本機快照 · \(relativeTime($0))" } ?? "本機快照"
        return u
    }

    // MARK: - Claude — 退回呼叫官方 /usage API

    /// 回傳 (用量, keychainDenied)。denied 為 true 時呼叫端應停止本 session 後續鑰匙圈嘗試。
    private static func fetchClaudeUsageFromAPI() async -> (usage: CLIUsage, keychainDenied: Bool) {
        var u = CLIUsage(name: "Claude Code")
        let (maybeToken, denied) = readClaudeToken()
        if denied {
            u.status = "已略過鑰匙圈授權（本次啟動已拒絕）"
            return (u, true)
        }
        guard let token = maybeToken else {
            u.status = "找不到 Claude 憑證（請先在 Claude Code 登入）"
            return (u, false)
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("macprism", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.status = "回應異常"; return (u, false)
            }
            if http.statusCode == 401 {
                u.status = "憑證已過期，請重新登入 Claude Code"; return (u, false)
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                u.status = "API 錯誤（\(http.statusCode)）"; return (u, false)
            }

            if let fiveHour = json["five_hour"] as? [String: Any] {
                u.usedPercent = num(fiveHour["utilization"]) ?? 0
                u.resetAt = parseISO(fiveHour["resets_at"] as? String)
            }
            if let sevenDay = json["seven_day"] as? [String: Any] {
                u.weekUsedPercent = num(sevenDay["utilization"])
                u.weekResetAt = parseReset(sevenDay["resets_at"])
            }
            u.available = true
            u.status = "API · 已更新"
            return (u, false)
        } catch {
            u.status = "連線失敗"
            return (u, false)
        }
    }

    /// 從 macOS Keychain 取出 Claude Code 的 OAuth access token。
    /// 首次存取時系統會跳出鑰匙圈授權提示，按「允許」即可。
    /// 回傳 (token, denied)：denied 為 true 表示使用者按了「拒絕」或授權失敗，
    /// 呼叫端應停止本 session 後續嘗試，避免每次刷新都跳窗。
    private static func readClaudeToken() -> (token: String?, denied: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // 使用者按「拒絕」或鑰匙圈授權失敗 → 標記 denied，讓上層不再重試
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return (nil, true)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return (nil, false) }
        return (token, false)
    }

    // MARK: - Codex（讀本機 rollout 檔內建的 rate-limit 快照）

    private static func readCodexUsage() async -> CLIUsage {
        var u = CLIUsage(name: "Codex")
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        guard let newest = newestRollout(in: sessions) else {
            u.status = "找不到 Codex session"
            return u
        }
        guard let content = try? String(contentsOf: newest, encoding: .utf8) else {
            u.status = "讀取 session 失敗"
            return u
        }

        // 由後往前找最後一筆帶 rate_limits 的事件
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("rate_limits"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any]
            else { continue }

            if let primary = rateLimits["primary"] as? [String: Any] {
                u.usedPercent = num(primary["used_percent"]) ?? 0
                u.resetAt = parseReset(primary["resets_at"])
            }
            if let secondary = rateLimits["secondary"] as? [String: Any] {
                u.weekUsedPercent = num(secondary["used_percent"])
                u.weekResetAt = parseReset(secondary["resets_at"])
            }
            u.available = true
            u.status = "本機 session 檔"
            return u
        }

        u.status = "session 中無配額資料"
        return u
    }

    /// 遞迴找 `~/.codex/sessions` 下修改時間最新的 rollout 檔
    private static func newestRollout(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" || url.pathExtension == "json"
            else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || mod > best!.date { best = (url, mod) }
        }
        return best?.url
    }

    // MARK: - 共用小工具

    /// JSON 數值統一轉 Double（涵蓋整數 / 浮點）
    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// 解析重置時間：可能是 ISO8601 字串，也可能是 Unix epoch 秒數
    private static func parseReset(_ value: Any?) -> Date? {
        if let s = value as? String { return parseISO(s) }
        if let secs = num(value) { return Date(timeIntervalSince1970: secs) }
        return nil
    }

    /// 把過去時間點描述成「剛剛 / X 分鐘前 / X 小時前」
    private static func relativeTime(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 90 { return "剛剛" }
        let minutes = Int(secs / 60)
        if minutes < 60 { return "\(minutes) 分鐘前" }
        return "\(minutes / 60) 小時前"
    }

    /// 解析 ISO8601 字串。先去掉小數秒（ISO8601DateFormatter 只吃 3 位、來源是 6 位）。
    private static func parseISO(_ string: String?) -> Date? {
        guard var s = string else { return nil }
        if let range = s.range(of: #"\.\d+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}
