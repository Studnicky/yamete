// IOHIDPublic.h — bridging header for public IOKit HID Event System headers.
//
// SwiftPM does not expose these hidsystem headers directly, so this C target
// re-exports the public SDK interfaces for use from Swift code.

#ifndef IOHIDPublic_h
#define IOHIDPublic_h

// Public SDK headers — these define IOHIDEventSystemClientRef,
// IOHIDServiceClientRef, and the documented API functions.
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

#endif /* IOHIDPublic_h */
