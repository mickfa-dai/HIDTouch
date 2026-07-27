#include "include/VirtualHIDHelper.h"

IOHIDUserDeviceRef _Nullable HIDTouch_CreateVirtualUserDevice(CFDictionaryRef _Nonnull properties) {
    return IOHIDUserDeviceCreate(kCFAllocatorDefault, properties);
}

IOReturn HIDTouch_HandleUserDeviceReport(IOHIDUserDeviceRef _Nonnull device, const uint8_t * _Nonnull reportData, CFIndex length) {
    return IOHIDUserDeviceHandleReport(device, (uint8_t *)reportData, length);
}
