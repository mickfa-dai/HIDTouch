#ifndef VirtualHIDHelper_h
#define VirtualHIDHelper_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOHIDUserDevice * IOHIDUserDeviceRef;

// Forward declaration of IOHIDUserDevice C API exported by IOKit framework
IOHIDUserDeviceRef _Nullable IOHIDUserDeviceCreate(CFAllocatorRef _Nullable allocator, CFDictionaryRef _Nonnull properties);
IOReturn IOHIDUserDeviceHandleReport(IOHIDUserDeviceRef _Nonnull device, uint8_t * _Nonnull report, CFIndex reportLength);

IOHIDUserDeviceRef _Nullable HIDTouch_CreateVirtualUserDevice(CFDictionaryRef _Nonnull properties);
IOReturn HIDTouch_HandleUserDeviceReport(IOHIDUserDeviceRef _Nonnull device, const uint8_t * _Nonnull reportData, CFIndex length);

#ifdef __cplusplus
}
#endif

#endif /* VirtualHIDHelper_h */
