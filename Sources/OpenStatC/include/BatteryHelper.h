#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    bool   present;          // 系統有電池
    int    percent;          // 0-100
    bool   isCharging;
    bool   isPluggedIn;      // 接 AC
    int    timeToEmptyMin;   // -1 表示 calculating/不適用
    int    timeToFullMin;    // -1 表示 calculating/不適用
    double powerWatts;       // 瞬時功率（絕對值）；無法取得時為 0
    int    cycleCount;       // 充放電循環次數；無法取得時為 0
    double currentCapacityWh;// 當前剩餘電量（Wh）；無法取得時為 0
    double maxCapacityWh;    // 滿充電量（Wh）；無法取得時為 0
} BatteryInfo;

BatteryInfo getBatteryInfo(void);
