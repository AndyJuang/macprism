#include "SensorHelper.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

// ───────────────────────────────────────────────────────────────
// 溫度：IOHIDEventSystemClient（私有 API，Apple Silicon 唯一可靠來源）
// ───────────────────────────────────────────────────────────────

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t eventType, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperature (kIOHIDEventTypeTemperature << 16)

static IOHIDEventSystemClientRef gTempClient = NULL;
static CFArrayRef gTempServices = NULL;

static void initTempClient(void) {
    if (gTempClient != NULL) return;
    gTempClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (gTempClient == NULL) return;

    int page = 0xff00;   // kHIDPage_AppleVendor
    int usage = 5;       // kHIDUsage_AppleVendor_TemperatureSensor
    CFNumberRef pageNum  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    CFStringRef keys[2]  = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[2]  = { pageNum, usageNum };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault,
        (const void **)keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    IOHIDEventSystemClientSetMatching(gTempClient, matching);
    gTempServices = IOHIDEventSystemClientCopyServices(gTempClient);

    CFRelease(matching);
    CFRelease(pageNum);
    CFRelease(usageNum);
}

int getTemperatureSensors(TempSensor *out, int maxCount) {
    initTempClient();
    if (gTempServices == NULL) return 0;

    int count = 0;
    CFIndex n = CFArrayGetCount(gTempServices);
    for (CFIndex i = 0; i < n && count < maxCount; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gTempServices, i);
        if (service == NULL) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (event == NULL) continue;
        double celsius = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperature);
        CFRelease(event);
        if (celsius <= 0.0 || celsius > 150.0) continue;

        char nameBuf[80] = {0};
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name != NULL) {
            if (CFGetTypeID(name) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)name, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
            }
            CFRelease(name);
        }
        if (nameBuf[0] == '\0') snprintf(nameBuf, sizeof(nameBuf), "Sensor %ld", (long)i);

        strncpy(out[count].name, nameBuf, sizeof(out[count].name) - 1);
        out[count].name[sizeof(out[count].name) - 1] = '\0';
        out[count].celsius = celsius;
        count++;
    }
    return count;
}

// ───────────────────────────────────────────────────────────────
// 風扇：AppleSMC
// ───────────────────────────────────────────────────────────────

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    char           result, status, data8;
    uint32_t       data32;
    unsigned char  bytes[32];
} SMCKeyData_t;

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_KEYINFO  9

static io_connect_t gSMCConn = 0;
static int gSMCTried = 0;

static void initSMC(void) {
    if (gSMCTried) return;
    gSMCTried = 1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (svc == 0) return;
    IOServiceOpen(svc, mach_task_self(), 0, &gSMCConn);
    IOObjectRelease(svc);
}

static uint32_t smcKey(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16)
         | ((uint32_t)(unsigned char)s[2] << 8)  |  (uint32_t)(unsigned char)s[3];
}

// 讀一個 SMC key 的原始 bytes，回傳 dataType；失敗回 0
static uint32_t smcRead(const char *key, unsigned char *bytes, uint32_t *dataSize) {
    if (gSMCConn == 0) return 0;
    SMCKeyData_t in, out;
    size_t outSize;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key   = smcKey(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    outSize  = sizeof(out);
    if (IOConnectCallStructMethod(gSMCConn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess)
        return 0;
    uint32_t type = out.keyInfo.dataType;
    uint32_t size = out.keyInfo.dataSize;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key              = smcKey(key);
    in.keyInfo.dataSize = size;
    in.data8            = SMC_CMD_READ_BYTES;
    outSize             = sizeof(out);
    if (IOConnectCallStructMethod(gSMCConn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess)
        return 0;

    if (size > 32) size = 32;
    memcpy(bytes, out.bytes, size);
    *dataSize = size;
    return type;
}

// 解析 SMC 數值（flt 浮點 / fpe2 定點 / 整數）
static double smcDecode(uint32_t type, const unsigned char *b, uint32_t size) {
    if (type == smcKey("flt ") && size == 4) {
        float f;
        memcpy(&f, b, 4);
        return (double)f;
    }
    if (type == smcKey("fpe2") && size == 2) {
        return (double)(((b[0] << 8) | b[1]) >> 2);
    }
    if (size == 1) return (double)b[0];
    if (size >= 2) return (double)((b[0] << 8) | b[1]);
    return 0.0;
}

static double smcReadValue(const char *key) {
    unsigned char bytes[32];
    uint32_t size = 0;
    uint32_t type = smcRead(key, bytes, &size);
    if (type == 0) return -1.0;
    return smcDecode(type, bytes, size);
}

int getFans(FanReading *out, int maxCount) {
    initSMC();
    if (gSMCConn == 0) return 0;

    double fnum = smcReadValue("FNum");
    if (fnum < 1.0) return 0;

    int n = (int)fnum;
    if (n > maxCount) n = maxCount;
    for (int i = 0; i < n; i++) {
        char key[5];
        snprintf(key, sizeof(key), "F%dAc", i);
        double ac = smcReadValue(key);
        out[i].actualRPM = ac < 0 ? 0 : (int)ac;
        snprintf(key, sizeof(key), "F%dMn", i);
        double mn = smcReadValue(key);
        out[i].minRPM = mn < 0 ? 0 : (int)mn;
        snprintf(key, sizeof(key), "F%dMx", i);
        double mx = smcReadValue(key);
        out[i].maxRPM = mx < 0 ? 0 : (int)mx;
    }
    return n;
}
