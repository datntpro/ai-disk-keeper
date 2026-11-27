#include "CNVMeSMART.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

_Static_assert(sizeof(NVMeSMARTData) == ADK_NVME_SMART_PAGE_SIZE, "NVMe SMART page must be 512 bytes");

static int is_internal(io_service_t service) {
    CFTypeRef loc = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("Physical Interconnect Location"),
                                                    kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!loc) return 1;  // unknown: still try; the "NVMe SMART Capable" key is the real gate
    int internal = CFGetTypeID(loc) == CFStringGetTypeID() && CFStringCompare(loc, CFSTR("Internal"), 0) == kCFCompareEqualTo;
    CFRelease(loc);
    return internal;
}

static int32_t read_from(io_service_t service, uint8_t *out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
                                                         &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) return kr != KERN_SUCCESS ? (int32_t)kr : -1;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    int32_t result;
    if (hr != S_OK || !smart) {
        result = -1;
    } else if ((*smart)->version != 1) {
        result = -2;
        (*smart)->Release(smart);
    } else {
        NVMeSMARTData page;
        memset(&page, 0, sizeof page);
        IOReturn r = (*smart)->SMARTReadData(smart, &page);
        if (r == kIOReturnSuccess) memcpy(out, &page, ADK_NVME_SMART_PAGE_SIZE);
        result = (int32_t)r;
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return result;
}

int32_t adk_nvme_smart_read(uint8_t out[ADK_NVME_SMART_PAGE_SIZE]) {
    memset(out, 0, ADK_NVME_SMART_PAGE_SIZE);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it) != KERN_SUCCESS) return -1;
    int32_t result = -1;
    io_service_t service;
    while ((service = IOIteratorNext(it)) != 0) {
        CFTypeRef cap = IORegistryEntryCreateCFProperty(service, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        int capable = cap && CFGetTypeID(cap) == CFBooleanGetTypeID() && CFBooleanGetValue(cap);
        if (cap) CFRelease(cap);
        if (capable && is_internal(service)) {
            result = read_from(service, out);
            IOObjectRelease(service);
            if (result == 0) break;
            continue;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return result;
}
