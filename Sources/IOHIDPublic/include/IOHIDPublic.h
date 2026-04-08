// IOHIDPublic.h — C interface for IOKit HID Event System API
//
// Includes Apple's public SDK headers for IOHIDEventSystemClient and
// IOHIDServiceClient, then declares additional functions that are exported
// from IOKit.framework but lack headers in the SDK.
//
// This module lets Swift code call these functions through standard C interop.

#ifndef IOHIDPublic_h
#define IOHIDPublic_h

// Public SDK headers — these define IOHIDEventSystemClientRef,
// IOHIDServiceClientRef, and the documented API functions.
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

__BEGIN_DECLS
CF_ASSUME_NONNULL_BEGIN

// MARK: - Exported from IOKit.framework, no public header
//
// These symbols are exported (visible in dyld_info -exports) and used by
// Apple's own tools. Standard C extern declarations make them callable
// from Swift without @_silgen_name.

/// Creates a full HID event system client with event delivery capability.
/// Unlike CreateSimpleClient, this client can set properties (e.g. ReportInterval)
/// on hardware services and successfully activate sleeping sensors.
IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);

/// Activates the client for event delivery.
void IOHIDEventSystemClientActivate(IOHIDEventSystemClientRef client);

/// Cancels an active client, stopping event delivery.
void IOHIDEventSystemClientCancel(IOHIDEventSystemClientRef client);

/// Sets a matching dictionary to filter which services are visible.
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client,
                                       CFDictionaryRef matching);

/// Schedules the client on a dispatch queue for event delivery.
void IOHIDEventSystemClientScheduleWithDispatchQueue(
    IOHIDEventSystemClientRef client,
    dispatch_queue_t queue);

CF_ASSUME_NONNULL_END
__END_DECLS

#endif /* IOHIDPublic_h */
