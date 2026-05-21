#include "DiskHelper.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <string.h>

static uint64_t cfNumberToUInt64(CFNumberRef num) {
    int64_t v = 0;
    if (num) CFNumberGetValue(num, kCFNumberSInt64Type, &v);
    return (uint64_t)(v < 0 ? 0 : v);
}

DiskIOStats getDiskIOStats(void) {
    DiskIOStats result = {0, 0};

    CFMutableDictionaryRef match = IOServiceMatching(kIOBlockStorageDriverClass);
    if (!match) return result;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) {
        return result;
    }

    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iter))) {
        CFDictionaryRef stats = (CFDictionaryRef)IORegistryEntryCreateCFProperty(
            entry, CFSTR(kIOBlockStorageDriverStatisticsKey), kCFAllocatorDefault, 0);

        if (stats) {
            CFNumberRef r = (CFNumberRef)CFDictionaryGetValue(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey));
            CFNumberRef w = (CFNumberRef)CFDictionaryGetValue(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey));
            result.bytesRead    += cfNumberToUInt64(r);
            result.bytesWritten += cfNumberToUInt64(w);
            CFRelease(stats);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return result;
}

int getDiskVolumes(DiskVolumeInfo *out, int maxCount) {
    if (!out || maxCount <= 0) return 0;

    struct statfs *mounts = NULL;
    int n = getmntinfo(&mounts, MNT_NOWAIT);
    if (n <= 0) return 0;

    // 每顆實體磁碟只收一次
    char seenDisks[16][16];
    int seenCount = 0;

    int count = 0;
    for (int i = 0; i < n && count < maxCount; i++) {
        const struct statfs *m = &mounts[i];
        if ((m->f_flags & MNT_LOCAL) == 0) continue;

        // 只保留掛在 "/" 或 "/Volumes/" 的卷宗 —— 即「整顆磁碟」；
        // APFS 拆出的 /System/Volumes/* 系統磁區一律略過，不分磁區
        int isRoot    = (strcmp(m->f_mntonname, "/") == 0);
        int isVolumes = (strncmp(m->f_mntonname, "/Volumes/", 9) == 0);
        if (!isRoot && !isVolumes) continue;

        uint64_t bsize = (uint64_t)m->f_bsize;
        uint64_t total = (uint64_t)m->f_blocks * bsize;
        if (total == 0) continue;

        // 由 device 取實體磁碟 id（/dev/disk3s1s1 → disk3），同一磁碟只收一次
        char diskID[16] = {0};
        const char *dev = strstr(m->f_mntfromname, "disk");
        if (dev) {
            int k = 0;
            while (k < 15 && dev[k]) {
                char c = dev[k];
                if (k < 4) diskID[k] = c;                       // "disk"
                else if (c >= '0' && c <= '9') diskID[k] = c;   // 磁碟編號
                else break;
                k++;
            }
            diskID[k] = '\0';
        }
        int dup = 0;
        for (int s = 0; s < seenCount; s++) {
            if (strcmp(seenDisks[s], diskID) == 0) { dup = 1; break; }
        }
        if (dup) continue;
        if (seenCount < 16 && diskID[0] != '\0') {
            strncpy(seenDisks[seenCount], diskID, 15);
            seenDisks[seenCount][15] = '\0';
            seenCount++;
        }

        out[count].totalBytes = total;
        out[count].freeBytes  = (uint64_t)m->f_bavail * bsize;
        strncpy(out[count].mountPoint, m->f_mntonname, sizeof(out[count].mountPoint) - 1);
        out[count].mountPoint[sizeof(out[count].mountPoint) - 1] = '\0';
        strncpy(out[count].name, m->f_mntfromname, sizeof(out[count].name) - 1);
        out[count].name[sizeof(out[count].name) - 1] = '\0';
        count++;
    }
    return count;
}
