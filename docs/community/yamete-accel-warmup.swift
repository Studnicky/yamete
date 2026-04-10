// yamete-accel-warmup.swift
//
// Warms the built-in BMI286 accelerometer on Apple Silicon Macs so that
// the Yamete App Store build can passively subscribe to the 100Hz HID
// report stream via IOHIDManager.
//
// Why this exists: the App Store build of Yamete runs under App Sandbox.
// Sandboxed apps cannot write `IORegistryEntrySetCFProperty` to the
// `AppleSPUHIDDriver` service — the kernel silently drops the write.
// This helper runs from outside App Sandbox (via a LaunchDaemon), so its
// writes reach the driver and start the sensor streaming. Yamete then
// subscribes passively and receives the existing report stream.
//
// Warmth persists across subscriber cycles, so this only needs to run
// once per boot. A single LaunchDaemon `RunAtLoad = true` is sufficient.
//
// Build:
//   swiftc yamete-accel-warmup.swift -o yamete-accel-warmup \
//          -framework IOKit -framework Foundation
//
// Install:
//   see install.sh in the same gist
//
// Source of truth: https://github.com/Studnicky/yamete/blob/develop/docs/community/

import Foundation
import IOKit

// MARK: - IORegistry helpers

/// Iterates every `AppleSPUHIDDriver` service flagged `dispatchAccel = Yes`
/// and invokes `body` on each. The SPU bus also hosts gyro, temperature,
/// and hinge-angle services; `dispatchAccel` disambiguates.
func iterateAccelServices(_ body: (io_service_t) -> Void) {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("AppleSPUHIDDriver")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        FileHandle.standardError.write(
            "yamete-accel-warmup: IOServiceGetMatchingServices failed — AppleSPUHIDDriver class not present (Intel Mac or unsupported macOS version)\n".data(using: .utf8)!
        )
        return
    }
    defer { IOObjectRelease(iterator) }

    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }
        defer { IOObjectRelease(service) }

        let dispatchAccel = IORegistryEntryCreateCFProperty(
            service, "dispatchAccel" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool ?? false
        guard dispatchAccel else { continue }

        body(service)
    }
}

// MARK: - Commands

/// Reports whether the accelerometer driver has emitted a report within
/// the last 500ms. Exit code 0 = streaming, 1 = cold, 2 = no hardware.
func probe() -> Int32 {
    var found = false
    var active = false
    var details: [String] = []

    iterateAccelServices { service in
        found = true

        let debug = IORegistryEntryCreateCFProperty(
            service, "DebugState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let numEvents = (debug?["_num_events"] as? Int) ?? 0
        let lastTsRaw = (debug?["_last_event_timestamp"] as? Int) ?? 0
        details.append("_num_events=\(numEvents)")
        details.append("_last_event_timestamp=0x\(String(lastTsRaw, radix: 16))")

        guard lastTsRaw > 0 else {
            details.append("staleness=∞ (no reports ever emitted since boot)")
            return
        }
        let lastTs = UInt64(lastTsRaw)
        let now = mach_absolute_time()
        guard now > lastTs else { return }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let deltaNs = (now - lastTs) &* UInt64(timebase.numer) / UInt64(timebase.denom)
        let deltaMs = Double(deltaNs) / 1_000_000.0
        details.append(String(format: "staleness=%.1fms", deltaMs))
        if deltaNs < 500_000_000 { active = true }
    }

    if !found {
        print("probe: no AppleSPUHIDDriver dispatchAccel=Yes service found")
        return 2
    }
    print("probe: active=\(active)")
    details.forEach { print("  \($0)") }
    return active ? 0 : 1
}

/// Writes the three activation properties that tell the driver to start
/// the BMI286 streaming at 100Hz (ReportInterval = 10000 µs). The writes
/// are command channels — success doesn't update a stored value in the
/// IOKit property dict, it triggers a hardware command.
/// Exit code 0 on success, 1 on any write failure, 2 if no hardware.
func warmup(intervalUS: Int = 10000) -> Int32 {
    var anyFound = false
    var anySuccess = false
    iterateAccelServices { service in
        anyFound = true
        let r1 = IORegistryEntrySetCFProperty(
            service, "ReportInterval" as CFString, intervalUS as CFNumber
        )
        let r2 = IORegistryEntrySetCFProperty(
            service, "SensorPropertyReportingState" as CFString, 1 as CFNumber
        )
        let r3 = IORegistryEntrySetCFProperty(
            service, "SensorPropertyPowerState" as CFString, 1 as CFNumber
        )
        let ok = r1 == KERN_SUCCESS && r2 == KERN_SUCCESS && r3 == KERN_SUCCESS
        if ok { anySuccess = true }
        print(String(
            format: "warmup: r1=0x%08x r2=0x%08x r3=0x%08x ok=%@",
            r1, r2, r3, ok ? "true" : "false"
        ))
    }
    if !anyFound {
        FileHandle.standardError.write(
            "yamete-accel-warmup: no dispatchAccel=Yes service found — not an Apple Silicon MacBook with BMI286?\n".data(using: .utf8)!
        )
        return 2
    }
    return anySuccess ? 0 : 1
}

/// Opposite of warmup: writes 0 to the three activation properties to
/// stop the sensor streaming. Useful for testing fallback behavior.
func deactivate() -> Int32 {
    var anyFound = false
    iterateAccelServices { service in
        anyFound = true
        let r1 = IORegistryEntrySetCFProperty(
            service, "ReportInterval" as CFString, 0 as CFNumber
        )
        let r2 = IORegistryEntrySetCFProperty(
            service, "SensorPropertyReportingState" as CFString, 0 as CFNumber
        )
        let r3 = IORegistryEntrySetCFProperty(
            service, "SensorPropertyPowerState" as CFString, 0 as CFNumber
        )
        print(String(
            format: "deactivate: r1=0x%08x r2=0x%08x r3=0x%08x",
            r1, r2, r3
        ))
    }
    return anyFound ? 0 : 2
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: \(args[0]) [probe|warmup|deactivate]")
    print("")
    print("  probe       print the accelerometer streaming state and exit")
    print("              (exit 0 = active, 1 = cold, 2 = no hardware)")
    print("  warmup      start the BMI286 streaming at 100Hz")
    print("              (exit 0 = accepted by driver, 1 = write rejected, 2 = no hardware)")
    print("  deactivate  stop the BMI286 streaming (useful for testing)")
    exit(64)
}

switch args[1] {
case "probe":      exit(probe())
case "warmup":     exit(warmup())
case "deactivate": exit(deactivate())
default:
    FileHandle.standardError.write("unknown command: \(args[1])\n".data(using: .utf8)!)
    exit(64)
}
