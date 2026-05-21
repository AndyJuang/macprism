import Foundation
import Darwin

/// 一條目前的網路連線
struct ConnectionRow: Identifiable {
    let id = UUID()
    let command: String
    let remote: String
    let state: String
}

/// 一個 App 的累計流量（自行程啟動起算）
struct AppTrafficRow: Identifiable {
    let id = UUID()
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    var total: UInt64 { bytesIn + bytesOut }
}

/// 網路進階資訊：區域 / 公開 IP、地理位置、連線清單、各 App 流量。
/// 公開 IP 走對外查詢（ipinfo.io），其餘皆解析本機指令（lsof / nettop）。
final class NetworkInfoMonitor: ObservableObject {
    @Published var localIP: String = "—"
    @Published var publicIP: String = "查詢中…"
    @Published var ipLocation: String = ""
    @Published var connections: [ConnectionRow] = []
    @Published var appTraffic: [AppTrafficRow] = []

    private var lastExec: Date = .distantPast       // lsof / nettop
    private var lastPublicIP: Date = .distantPast
    private let execInterval: TimeInterval = 8       // 連線 / 流量每 8 秒
    private let publicIPInterval: TimeInterval = 1800 // 公開 IP 每 30 分鐘

    /// 由主計時器每 2 秒呼叫；內部各自節流。
    func refresh(force: Bool = false) {
        localIP = Self.currentLocalIP()

        let now = Date()
        if force || now.timeIntervalSince(lastExec) >= execInterval {
            lastExec = now
            Task {
                let conns   = Self.readConnections()
                let traffic = Self.readAppTraffic()
                await MainActor.run {
                    self.connections = conns
                    self.appTraffic  = traffic
                }
            }
        }
        if force || now.timeIntervalSince(lastPublicIP) >= publicIPInterval {
            lastPublicIP = now
            Task {
                if let info = await Self.fetchPublicIP() {
                    await MainActor.run {
                        self.publicIP   = info.ip
                        self.ipLocation = info.location
                    }
                }
            }
        }
    }

    // MARK: - 區域 IP（getifaddrs）

    private static func currentLocalIP() -> String {
        var result = "—"
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return result }
        defer { freeifaddrs(ifap) }

        var ptr = ifap
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                break
            }
        }
        return result
    }

    // MARK: - 公開 IP + 地理位置（ipinfo.io）

    private static func fetchPublicIP() async -> (ip: String, location: String)? {
        var req = URLRequest(url: URL(string: "https://ipinfo.io/json")!)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let ip = json["ip"] as? String ?? "—"
        let parts = [json["city"] as? String,
                     json["region"] as? String,
                     json["country"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        return (ip, parts.joined(separator: ", "))
    }

    // MARK: - 連線清單（lsof）

    private static func readConnections() -> [ConnectionRow] {
        guard let out = runCommand("/usr/sbin/lsof", ["-i", "-nP"]) else { return [] }
        var rows: [ConnectionRow] = []
        for line in out.split(separator: "\n") {
            guard line.contains("->") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2,
                  let nameField = parts.first(where: { $0.contains("->") }) else { continue }

            let remote = nameField.components(separatedBy: "->").last ?? nameField
            var state = ""
            if let last = parts.last, last.hasPrefix("(") {
                state = last.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            rows.append(ConnectionRow(command: parts[0], remote: remote, state: state))
            if rows.count >= 12 { break }
        }
        return rows
    }

    // MARK: - 各 App 流量（nettop）

    private static func readAppTraffic() -> [AppTrafficRow] {
        guard let out = runCommand("/usr/bin/nettop",
                                   ["-P", "-x", "-l", "1", "-J", "bytes_in,bytes_out"]) else { return [] }
        var rows: [AppTrafficRow] = []
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.contains("bytes_in") { continue }   // 跳過標頭
            let tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3,
                  let bin  = UInt64(tokens[tokens.count - 2]),
                  let bout = UInt64(tokens[tokens.count - 1]) else { continue }

            var name = tokens[0..<(tokens.count - 2)].joined(separator: " ")
            // 去掉結尾的 .pid
            if let dot = name.lastIndex(of: "."),
               !name[name.index(after: dot)...].isEmpty,
               name[name.index(after: dot)...].allSatisfy(\.isNumber) {
                name = String(name[..<dot])
            }
            let row = AppTrafficRow(name: name, bytesIn: bin, bytesOut: bout)
            if row.total > 0 { rows.append(row) }
        }
        return Array(rows.sorted { $0.total > $1.total }.prefix(6))
    }

    // MARK: - 執行外部指令

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
