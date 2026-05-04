# OpenStat

<p align="center">
  <img src="Assets/AppIcon.iconset/icon_128x128.png" width="128" alt="OpenStat icon">
</p>

<p align="center">
  輕量原生的 macOS 系統監控工具，常駐於 menu bar，即時顯示 CPU、記憶體與網路流量。
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
| **CPU** | 整體使用率 + 各核心柱狀圖，`host_processor_info` 原生 API |
| **記憶體** | Active / Wired / Compressed 分層顯示，`vm_statistics64` |
| **網路** | 上傳／下載即時速率，跨所有非 loopback 介面加總 |
| **固定寬度** | 等寬字型（SF Mono），數值更新不會讓 menu bar 跳動 |
| **登入自動啟動** | 右鍵選單一鍵切換，使用 `SMAppService` |

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
| **右鍵** | 「登入時自動啟動」開關 / 結束 |

## 技術架構

```
openstat/
├── Sources/
│   ├── OpenStatC/          # C 層：getifaddrs 讀取網路 bytes
│   │   ├── include/NetworkHelper.h
│   │   └── NetworkHelper.c
│   └── OpenStat/           # Swift 主程式
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── StatusBarController.swift   # menu bar + 右鍵選單
│       ├── SystemMonitor.swift         # CPU / 記憶體 / 網路數據
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

## 系統需求

- macOS 13 Ventura 或更新版本
- Apple Silicon 或 Intel Mac

## 授權

[MIT License](LICENSE) © 2026 Andy Juang
