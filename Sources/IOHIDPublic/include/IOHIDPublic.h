// IOHIDPublic.h — bridging header for public IOKit HID Event System headers.
//
// SwiftPM does not expose the hidsystem headers directly, so this C target
// re-exports the public SDK interfaces for use from Swift code.
//
// All functions used by the accelerometer adapter are declared in these
// public SDK headers. No private or undocumented symbols are referenced.

#ifndef IOHIDPublic_h
#define IOHIDPublic_h

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

#endif /* IOHIDPublic_h */
