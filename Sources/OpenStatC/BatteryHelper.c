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

        // 電池健康度 = 滿充電容量 ÷ 設計電容量
        CFNumberRef rawMx  = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
        CFNumberRef design = (CFNumberRef)IORegistryEntryCreateCFProperty(batt, CFSTR("DesignCapacity"), kCFAllocatorDefault, 0);
        if (rawMx && design) {
            int64_t r = 0, d = 0;
            CFNumberGetValue(rawMx,  kCFNumberSInt64Type, &r);
            CFNumberGetValue(design, kCFNumberSInt64Type, &d);
            if (d > 0) {
                int h = (int)((double)r / (double)d * 100.0 + 0.5);
                info.healthPercent = h > 100 ? 100 : h;   // 新電池 raw 容量可能略高於設計值
            }
        }
        if (rawMx)  CFRelease(rawMx);
        if (design) CFRelease(design);

        if (amp) CFRelease(amp);
        if (vol) CFRelease(vol);
        if (cyc) CFRelease(cyc);
        if (cur) CFRelease(cur);
        if (mx)  CFRelease(mx);
        IOObjectRelease(batt);
    }

    return info;
}

int getBluetoothBatteries(BTDevice *out, int maxCount) {
    io_iterator_t iter = 0;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
            kIORegistryIterateRecursively, &iter) != KERN_SUCCESS) {
        return 0;
    }

    int count = 0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iter)) != 0 && count < maxCount) {
        CFTypeRef pct = IORegistryEntryCreateCFProperty(entry, CFSTR("BatteryPercent"), kCFAllocatorDefault, 0);
        if (pct) {
            int percent = 0;
            if (CFGetTypeID(pct) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)pct, kCFNumberIntType, &percent);
            }
            CFRelease(pct);

            if (percent > 0 && percent <= 100) {
                char nameBuf[80] = {0};
                CFTypeRef product = IORegistryEntryCreateCFProperty(entry, CFSTR("Product"), kCFAllocatorDefault, 0);
                if (product) {
                    if (CFGetTypeID(product) == CFStringGetTypeID()) {
                        CFStringGetCString((CFStringRef)product, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
                    }
                    CFRelease(product);
                }
                if (nameBuf[0] == '\0') {
                    io_name_t rname;
                    if (IORegistryEntryGetName(entry, rname) == KERN_SUCCESS) {
                        strncpy(nameBuf, rname, sizeof(nameBuf) - 1);
                    }
                }
                if (nameBuf[0] == '\0') strncpy(nameBuf, "藍牙裝置", sizeof(nameBuf) - 1);

                strncpy(out[count].name, nameBuf, sizeof(out[count].name) - 1);
                out[count].name[sizeof(out[count].name) - 1] = '\0';
                out[count].percent = percent;
                count++;
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return count;
}
