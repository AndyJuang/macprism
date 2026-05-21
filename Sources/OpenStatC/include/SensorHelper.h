#pragma once

typedef struct {
    char   name[80];     // 感測器名稱（Product 屬性）
    double celsius;      // 溫度（°C）
} TempSensor;

typedef struct {
    int actualRPM;       // 目前轉速
    int minRPM;          // 最低轉速
    int maxRPM;          // 最高轉速
} FanReading;

// 透過 IOHIDEventSystemClient 讀取溫度感測器，回傳寫入數量
int getTemperatureSensors(TempSensor *out, int maxCount);

// 透過 AppleSMC 讀取風扇，回傳風扇數（0 = 無風扇或讀不到）
int getFans(FanReading *out, int maxCount);
