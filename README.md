# OpenStat

<p align="center">
  <img src="Assets/icon.png" width="128" alt="OpenStat icon">
</p>

<p align="center">
  輕量原生的 macOS 系統監控工具，常駐於 menu bar，即時顯示 CPU、GPU、記憶體、磁碟、網路、電池與 Top Process。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9">
  <img src="https://img.shields.io/github/license/AndyJuang/openstat" alt="MIT License">
  <img src="https://img.shields.io/github/v/release/AndyJuang/openstat" alt="Latest release">
</p>

---

## 功能

| 項目 | 說明 |
|------|------|
| **CPU** | 整體使用率 + 各核心柱狀圖、load average、開機時間，`host_processor_info` |
| **記憶體** | Active / Wired / Compressed 分層、Swap 用量、記憶體壓力，`vm_statistics64` |
| **網路** | 上傳／下載速率與走勢圖、區域／公開 IP、地理位置、App 流量排行、連線清單 |
| **GPU** | 使用率與配置記憶體，透過 IORegistry `IOAccelerator` |
| **磁碟** | 全系統讀寫速率（`IOBlockStorageDriver`）+ 各掛載點容量（`getmntinfo`） |
| **電池** | 電量、充電狀態、瞬時功率（W）、循環次數、健康度、藍牙裝置電量 |
| **感測器** | 溫度感測器（`IOHIDEventSystemClient`）+ 風扇轉速（`AppleSMC`） |
| **Top Process** | CPU / 記憶體 Top 5 排行（`libproc`），詳細面板可切換 |
| **AI 額度** | Claude Code / Codex 目前 5 小時視窗剩餘額度、重置倒數與每週用量 |
| **日期** | menu bar 日期 + 下拉面板當月月曆 |
| **固定寬度** | 等寬字型（SF Mono），數值更新不會讓 menu bar 跳動 |
| **登入自動啟動** | 右鍵選單一鍵切換，使用 `SMAppService` |
| **走勢圖** | CPU / 記憶體 / GPU / 網路面板皆附迷你折線走勢（最近 2 分鐘） |
| **Menu Bar 自訂** | 右鍵 → Menu Bar 顯示可開關各項，並可顯示 CPU 走勢小圖 |

## 截圖

| Menu Bar | 詳細面板 |
|----------|---------|
| `CPU  45%  12.3G  ↑  1.2M  ↓  5.8M` | *(點擊 menu bar 圖示開啟)* |

## 安裝

### 下載（推薦）

前往 [Releases](https://github.com/AndyJuang/openstat/releases/latest) 下載 `OpenStat.dmg`，掛載後將 **OpenStat.app** 拖入 Applications 資料夾。

> **首次開啟：** macOS 可能顯示「無法驗證開發者」，請至  
> **系統設定 → 隱私權與安全性 → 仍要開啟**。

### 從原始碼建置

**環境需求：** Xcode Command Line Tools、Swift 5.9+

```bash
git clone https://github.com/AndyJuang/openstat.git
cd openstat
make app          # 建置並打包成 OpenStat.app
open OpenStat.app
```

其他指令：

```bash
make run    # 直接在終端機執行（不打包）
make icon   # 重新產生 App icon
make clean  # 清除 build 產物
```

## 使用方式

| 操作 | 動作 |
|------|------|
| **左鍵** | 開啟詳細統計面板 |
| **右鍵** | Menu Bar 顯示項目、登入時自動啟動、結束 |

## 技術架構

```
openstat/
├── Sources/
│   ├── OpenStatC/          # C 層：IOKit / libproc / getifaddrs
│   │   ├── include/{Network,Disk,GPU,Battery,Process}Helper.h
│   │   ├── NetworkHelper.c
│   │   ├── DiskHelper.c
│   │   ├── GPUHelper.c
│   │   ├── BatteryHelper.c
│   │   └── ProcessHelper.c
│   └── OpenStat/           # Swift 主程式
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── StatusBarController.swift   # menu bar + 右鍵選單 + 顯示偏好
│       ├── SystemMonitor.swift         # 系統指標的資料蒐集與發佈
│       ├── TokenUsageMonitor.swift     # AI 額度（Claude / Codex）資料來源
│       └── ContentView.swift           # SwiftUI 面板 UI
├── Assets/
│   └── make_icon.swift     # Icon 產生腳本（AppKit 繪製）
├── Info.plist
├── Makefile
└── Package.swift
```

**CPU 監控：** 每 2 秒呼叫 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，計算 tick delta 得出使用率。

**記憶體監控：** `host_statistics64(HOST_VM_INFO64)` 取得各頁面計數，乘以 page size。

**網路監控：** 透過 C helper 呼叫 `getifaddrs`，累加所有 AF\_LINK 介面的 `ifi_ibytes` / `ifi_obytes`，每 2 秒計算 delta。

**磁碟監控：** `IOServiceMatching("IOBlockStorageDriver")` 列舉所有區塊裝置，從 `Statistics` 屬性的 `Bytes (Read)` / `Bytes (Write)` 計算 delta；容量則用 `getmntinfo` + `MNT_LOCAL` 篩選本機分割區。

**GPU 監控：** `IOServiceMatching("IOAccelerator")` 列舉 GPU，從 `PerformanceStatistics` 讀 `Device Utilization %`（Apple Silicon 也支援）。

**電池監控：** `IOPSCopyPowerSourcesInfo` 取電量／時間／充電狀態；`AppleSmartBattery` IORegistry 取 `Amperage` × `Voltage` 計算瞬時功率（W）。

**Top Process：** `proc_listpids` + `proc_pidinfo(PROC_PIDTASKINFO)` 取得各行程 CPU 累計時間與 RSS，依兩次取樣 delta 算出 CPU%。

**AI 額度：** Codex 直接讀 `~/.codex/sessions` 最新 rollout 檔內建的 rate-limit 快照（完全離線）。Claude Code 優先讀 `~/.claude/usage-status.json` —— 由 `statusline.sh` 擷取 statusLine 的 `rate_limits` 寫出（同樣離線、不動狀態列輸出）；缺檔或快照超過 6 小時才退回呼叫 `api.anthropic.com/api/oauth/usage`（OAuth 憑證取自 Keychain）。兩者皆聚焦「目前 5 小時滾動視窗」，每 60 秒刷新（API 退回路徑內部節流至 5 分鐘）。

**感測器：** 溫度透過私有 API `IOHIDEventSystemClient`（page `0xff00` / usage `5`）列舉所有溫度感測器 —— Apple Silicon 唯一可靠來源；風扇透過 `AppleSMC` 讀 `FNum` / `F?Ac` 等鍵。電池健康度為 `AppleRawMaxCapacity ÷ DesignCapacity`；藍牙裝置電量掃 IORegistry 帶 `BatteryPercent` 屬性的節點（涵蓋巧控滑鼠／鍵盤／觸控板，AirPods 不一定曝露）。

**網路進階：** 區域 IP 由 `getifaddrs` 取得；公開 IP 與地理位置查詢 `ipinfo.io`（每 30 分鐘、唯一的對外連線）；App 流量解析 `nettop` 輸出、連線清單解析 `lsof -i`（每 8 秒）。

## 系統需求

- macOS 13 Ventura 或更新版本
- Apple Silicon 或 Intel Mac

## 授權

[MIT License](LICENSE) © 2026 Andy Juang
