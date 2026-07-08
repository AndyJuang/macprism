#pragma once
#include <stdint.h>
#include <stdbool.h>

// 透過私有 MobileDevice.framework 讀取「USB 連接的 iOS 裝置」電量與充電狀態。
// coconutBattery / AlDente 採用同一套 AMDevice* API。非沙盒 app 才可用。
typedef struct {
    char name[80];      // 裝置名稱（DeviceName，例「Andy 的 iPhone」）；未信任時為通用名
    char kind[32];      // DeviceClass，例 "iPhone" / "iPad"
    int  percent;       // 電量 0-100；-1 = 無法取得（未信任）
    bool isCharging;     // 是否正在充電
    bool fullyCharged;   // 是否已充飽
    bool paired;        // 已配對且本機已被信任；false = 需在裝置上點「信任」
} IOSDeviceInfo;

// 啟動 USB 連接/中斷的監看（內部訂閱 AMDeviceNotification）。
// 必須在主執行緒（具 run loop）呼叫一次；重複呼叫安全。
void startIOSDeviceMonitoring(void);

// 讀取目前已連接的 iOS 裝置電量，填入 out（最多 maxCount 筆），回傳實際數量。
// 會對每台裝置做 connect/session/disconnect，請勿在高頻迴圈呼叫。
int getIOSDevices(IOSDeviceInfo *out, int maxCount);
