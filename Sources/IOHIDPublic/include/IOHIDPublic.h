// IOHIDPublic.h — C interface for IOKit HID Event System API
//
// Includes Apple's public SDK headers for IOHIDEventSystemClient and
// IOHIDServiceClient, then declares additional functions that are exported
// from IOKit.framework (confirmed via dyld_info -exports) but lack headers.
//
// This module lets Swift code call these functions through standard C interop
// without @_silgen_name bindings.

#ifndef IOHIDPublic_h
#define IOHIDPublic_h

// Public SDK headers — these define IOHIDEventSystemClientRef,
// IOHIDServiceClientRef, and the documented API functions.
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

__BEGIN_DECLS
CF_ASSUME_NONNULL_BEGIN

// MARK: - Exported but not in public headers
//
// These symbols are exported from IOKit.framework (visible in
// dyld_info -exports) and used by Apple's own tools and frameworks.
// Standard C extern declarations make them callable from Swift.

/// Creates a full HID event system client with event delivery capability.
/// Equivalent to the internal CreateWithType(allocator, kIOHIDEventSystemClientTypeMonitor, NULL).
/// Unlike CreateSimpleClient, this client type can receive events via callbacks
/// and successfully set properties (e.g. ReportInterval) on hardware services.
IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);

/// Activates the client for event delivery. Must be called after scheduling
/// with a dispatch queue or run loop.
void IOHIDEventSystemClientActivate(IOHIDEventSystemClientRef client);

/// Cancels an active client, stopping event delivery.
void IOHIDEventSystemClientCancel(IOHIDEventSystemClientRef client);

/// Sets a matching dictionary to filter which services are visible.
/// Keys: "PrimaryUsagePage", "PrimaryUsage", "Transport", etc.
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client,
                                       CFDictionaryRef matching);

/// Schedules the client on a dispatch queue for event delivery.
void IOHIDEventSystemClientScheduleWithDispatchQueue(
    IOHIDEventSystemClientRef client,
    dispatch_queue_t queue);

CF_ASSUME_NONNULL_END
__END_DECLS

#endif /* IOHIDPublic_h */
