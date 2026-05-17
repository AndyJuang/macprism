#include "BatteryHelper.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <math.h>

static int cfDictInt(CFDictionaryRef d, CFStringRef key, int fallback) {
    if (!d) return fallback;
    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(d, key);
    if (!n) return fallback;
    int v = fallback;
    CFNumberGetValue(n, kCFNumberIntType, &v);
    return v;
}

static bool cfDictBool(CFDictionaryRef d, CFStringRef key) {
    if (!d) return false;
    CFBooleanRef b = (CFBooleanRef)CFDictionaryGetValue(d, key);
    return b && CFBooleanGetValue(b);
}

BatteryInfo getBatteryInfo(void) {
    BatteryInfo info = {0};
    info.timeToEmptyMin = -1;
    info.timeToFullMin  = -1;

    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (!snapshot) return info;

    CFArrayRef sources = IOPSCopyPowerSourcesList(snapshot);
    if (!sources) { CFRelease(snapshot); return info; }

    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef ps = CFArrayGetValueAtIndex(sources, i);
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(snapshot, ps);
        if (!desc) continue;

        CFStringRef type = (CFStringRef)CFDictionaryGetValue(desc, CFSTR(kIOPSTypeKey));
        if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;

        info.present     = true;
        int current      = cfDictInt(desc, CFSTR(kIOPSCurrentCapacityKey), 0);
        int max          = cfDictInt(desc, CFSTR(kIOPSMaxCapacityKey), 100);
        info.percent     = max > 0 ? (current * 100 / max) : 0;
        info.isCharging  = cfDictBool(desc, CFSTR(kIOPSIsChargingKey));

        CFStringRef state = (CFStringRef)CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey));
        info.isPluggedIn  = state && CFEqual(state, CFSTR(kIOPSACPowerValue));

        int tte = cfDictInt(desc, CFSTR(kIOPSTimeToEmptyKey), -1);
        int ttf = cfDictInt(desc, CFSTR(kIOPSTimeToFullChargeKey), -1);
        info.timeToEmptyMin = tte > 0 ? tte : -1;
        info.timeToFullMin  = ttf > 0 ? ttf : -1;
        break;
    }

    CFRelease(sources);
    CFRelease(snapshot);

    // 從 AppleSmartBattery 取 Amperage × Voltage、CycleCount、容量
    io_service_t batt = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (batt) {
        CFNumberRef amp = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("Amperage"), kCFAllocatorDefault, 0);
        CFNumberRef vol = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("Voltage"),  kCFAllocatorDefault, 0);
        CFNumberRef cyc = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("CycleCount"), kCFAllocatorDefault, 0);
        CFNumberRef cur = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("AppleRawCurrentCapacity"), kCFAllocatorDefault, 0);
        if (!cur) cur = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
        CFNumberRef mx  = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
        if (!mx)  mx  = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("MaxCapacity"), kCFAllocatorDefault, 0);

        int64_t mV = 0;
        if (vol) CFNumberGetValue(vol, kCFNumberSInt64Type, &mV);

        if (amp && vol) {
            int64_t mA = 0;
            CFNumberGetValue(amp, kCFNumberSInt64Type, &mA);
            info.powerWatts = fabs((double)mA) * (double)mV / 1.0e6;
        }
        if (cyc) {
            int c = 0;
            CFNumberGetValue(cyc, kCFNumberIntType, &c);
            info.cycleCount = c;
        }
        if (cur && mV > 0) {
            int64_t mAh = 0;
            CFNumberGetValue(cur, kCFNumberSInt64Type, &mAh);
            info.currentCapacityWh = (double)mAh * (double)mV / 1.0e6;
        }
        if (mx && mV > 0) {
            int64_t mAh = 0;
            CFNumberGetValue(mx, kCFNumberSInt64Type, &mAh);
            info.maxCapacityWh = (double)mAh * (double)mV / 1.0e6;
        }

        if (amp) CFRelease(amp);
        if (vol) CFRelease(vol);
        if (cyc) CFRelease(cyc);
        if (cur) CFRelease(cur);
        if (mx)  CFRelease(mx);
        IOObjectRelease(batt);
    }

    return info;
}
