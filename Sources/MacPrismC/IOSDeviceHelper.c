#include "IOSDeviceHelper.h"
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <dlfcn.h>

// ---- 私有 MobileDevice.framework 函式原型 ----
// 該框架在磁碟上僅有 arm64e/x86_64 slice、無 arm64 連結 stub，靜態連結會失敗；
// 改用 dlopen/dlsym 於執行期載入（arm64 行程可正常載入 arm64e 系統框架）。
typedef struct am_device *AMDeviceRef;

typedef struct {
    AMDeviceRef device;
    int         messageType;   // 1 = 連接, 2 = 中斷, 3 = 取消訂閱
    int         _unknown;
} AMDeviceNotificationCallbackInfo;

typedef void (*AMDeviceNotificationCallback)(AMDeviceNotificationCallbackInfo *, void *);

typedef int  (*AMDeviceNotificationSubscribe_t)(AMDeviceNotificationCallback, int, int, void *, void **);
typedef int  (*AMDeviceConnect_t)(AMDeviceRef);
typedef int  (*AMDeviceDisconnect_t)(AMDeviceRef);
typedef int  (*AMDeviceIsPaired_t)(AMDeviceRef);
typedef int  (*AMDeviceValidatePairing_t)(AMDeviceRef);
typedef int  (*AMDeviceStartSession_t)(AMDeviceRef);
typedef int  (*AMDeviceStopSession_t)(AMDeviceRef);
typedef CFTypeRef (*AMDeviceCopyValue_t)(AMDeviceRef, CFStringRef, CFStringRef);
typedef void (*AMDeviceRetain_t)(AMDeviceRef);
typedef void (*AMDeviceRelease_t)(AMDeviceRef);

static AMDeviceNotificationSubscribe_t AMDeviceNotificationSubscribe;
static AMDeviceConnect_t               AMDeviceConnect;
static AMDeviceDisconnect_t            AMDeviceDisconnect;
static AMDeviceIsPaired_t              AMDeviceIsPaired;
static AMDeviceValidatePairing_t       AMDeviceValidatePairing;
static AMDeviceStartSession_t          AMDeviceStartSession;
static AMDeviceStopSession_t           AMDeviceStopSession;
static AMDeviceCopyValue_t             AMDeviceCopyValue;
static AMDeviceRetain_t                AMDeviceRetain;
static AMDeviceRelease_t               AMDeviceRelease;

static bool gLoaded = false;

// 載入 MobileDevice.framework 並解析所需符號；成功回傳 true（僅做一次）。
static bool loadMobileDevice(void) {
    static bool attempted = false;
    if (attempted) return gLoaded;
    attempted = true;

    void *h = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY);
    if (!h) return false;

    AMDeviceNotificationSubscribe = (AMDeviceNotificationSubscribe_t)dlsym(h, "AMDeviceNotificationSubscribe");
    AMDeviceConnect               = (AMDeviceConnect_t)dlsym(h, "AMDeviceConnect");
    AMDeviceDisconnect            = (AMDeviceDisconnect_t)dlsym(h, "AMDeviceDisconnect");
    AMDeviceIsPaired              = (AMDeviceIsPaired_t)dlsym(h, "AMDeviceIsPaired");
    AMDeviceValidatePairing       = (AMDeviceValidatePairing_t)dlsym(h, "AMDeviceValidatePairing");
    AMDeviceStartSession          = (AMDeviceStartSession_t)dlsym(h, "AMDeviceStartSession");
    AMDeviceStopSession           = (AMDeviceStopSession_t)dlsym(h, "AMDeviceStopSession");
    AMDeviceCopyValue             = (AMDeviceCopyValue_t)dlsym(h, "AMDeviceCopyValue");
    AMDeviceRetain                = (AMDeviceRetain_t)dlsym(h, "AMDeviceRetain");
    AMDeviceRelease               = (AMDeviceRelease_t)dlsym(h, "AMDeviceRelease");

    gLoaded = AMDeviceNotificationSubscribe && AMDeviceConnect && AMDeviceDisconnect &&
              AMDeviceIsPaired && AMDeviceValidatePairing && AMDeviceStartSession &&
              AMDeviceStopSession && AMDeviceCopyValue && AMDeviceRetain && AMDeviceRelease;
    return gLoaded;
}

#define ADNCI_MSG_CONNECTED    1
#define ADNCI_MSG_DISCONNECTED 2

#define MAX_IOS 8
static AMDeviceRef gDevices[MAX_IOS];
static int         gDeviceCount = 0;
static void       *gNotification = NULL;

static void deviceCallback(AMDeviceNotificationCallbackInfo *info, void *ctx) {
    (void)ctx;
    if (!info || !info->device) return;

    if (info->messageType == ADNCI_MSG_CONNECTED) {
        for (int i = 0; i < gDeviceCount; i++) {
            if (gDevices[i] == info->device) return;   // 已在清單
        }
        if (gDeviceCount < MAX_IOS) {
            AMDeviceRetain(info->device);
            gDevices[gDeviceCount++] = info->device;
        }
    } else if (info->messageType == ADNCI_MSG_DISCONNECTED) {
        for (int i = 0; i < gDeviceCount; i++) {
            if (gDevices[i] == info->device) {
                AMDeviceRelease(gDevices[i]);
                for (int j = i; j < gDeviceCount - 1; j++) gDevices[j] = gDevices[j + 1];
                gDeviceCount--;
                break;
            }
        }
    }
}

void startIOSDeviceMonitoring(void) {
    if (gNotification) return;
    if (!loadMobileDevice()) return;
    AMDeviceNotificationSubscribe(deviceCallback, 0, 0, NULL, &gNotification);
}

static void copyCFString(CFStringRef s, char *buf, int len) {
    buf[0] = '\0';
    if (s && CFGetTypeID(s) == CFStringGetTypeID()) {
        CFStringGetCString(s, buf, len, kCFStringEncodingUTF8);
    }
}

static int copyBatteryInt(AMDeviceRef d, CFStringRef key, int fallback) {
    CFTypeRef v = AMDeviceCopyValue(d, CFSTR("com.apple.mobile.battery"), key);
    int out = fallback;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out);
    }
    if (v) CFRelease(v);
    return out;
}

static bool copyBatteryBool(AMDeviceRef d, CFStringRef key) {
    CFTypeRef v = AMDeviceCopyValue(d, CFSTR("com.apple.mobile.battery"), key);
    bool out = false;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        out = CFBooleanGetValue((CFBooleanRef)v);
    }
    if (v) CFRelease(v);
    return out;
}

int getIOSDevices(IOSDeviceInfo *out, int maxCount) {
    if (!gLoaded) return 0;
    int n = 0;
    for (int i = 0; i < gDeviceCount && n < maxCount; i++) {
        AMDeviceRef d = gDevices[i];
        IOSDeviceInfo info;
        memset(&info, 0, sizeof(info));
        info.percent = -1;

        if (AMDeviceConnect(d) != 0) continue;

        bool sessionOpen = false;
        if (AMDeviceIsPaired(d) &&
            AMDeviceValidatePairing(d) == 0 &&
            AMDeviceStartSession(d) == 0) {
            sessionOpen   = true;
            info.paired   = true;

            CFStringRef name = (CFStringRef)AMDeviceCopyValue(d, NULL, CFSTR("DeviceName"));
            copyCFString(name, info.name, sizeof(info.name));
            if (name) CFRelease(name);

            CFStringRef cls = (CFStringRef)AMDeviceCopyValue(d, NULL, CFSTR("DeviceClass"));
            copyCFString(cls, info.kind, sizeof(info.kind));
            if (cls) CFRelease(cls);

            info.percent      = copyBatteryInt(d, CFSTR("BatteryCurrentCapacity"), -1);
            info.isCharging   = copyBatteryBool(d, CFSTR("BatteryIsCharging"));
            info.fullyCharged = copyBatteryBool(d, CFSTR("FullyCharged"));
        } else {
            info.paired = false;
            strncpy(info.name, "iOS 裝置", sizeof(info.name) - 1);
        }

        if (sessionOpen) AMDeviceStopSession(d);
        AMDeviceDisconnect(d);

        if (info.name[0] == '\0') strncpy(info.name, "iOS 裝置", sizeof(info.name) - 1);
        if (info.kind[0] == '\0') strncpy(info.kind, "iPhone", sizeof(info.kind) - 1);

        out[n++] = info;
    }
    return n;
}
