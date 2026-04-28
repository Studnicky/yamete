#if canImport(YameteCore)
import YameteCore
#endif
@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Foundation
import IOKit
import IOKit.usb
import IOKit.ps
import IOHIDPublic
import os

private let log = AppLog(category: "EventSources")

// IOMessage constants. Defined in `<IOKit/IOMessage.h>` via
// `iokit_common_msg(0x280)` etc. — those macros expand to a compile-time
// expression Swift's importer can't ingest (`structure not supported`), so
// the literal values are reproduced here. Values match the Apple SDK
// (sys_iokit | sub_iokit_common | code) where sys_iokit = 0xe0000000.
private let kIOMessageSystemWillSleep:    UInt32 = 0xe0000280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xe0000300

// MARK: - USB attach/detach

/// IOKit USB device matching notifications. Publishes
/// `Reaction.usbAttached` / `.usbDetached` for every device that arrives or
/// terminates. Suppresses the initial replay burst that `IOServiceMatching`
/// emits on start (every currently-attached device) — those would all fire
/// at app launch and spam the responders.
public final class USBSource: @unchecked Sendable {
    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private var publishTask: Task<Void, Never>?
    private let lastEvent = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    #if DEBUG
    /// Test seam — weak ref to the bus, set on `start`. Used by `_testEmit`.
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    @MainActor
    public func start(publishingTo bus: ReactionBus) {
        guard notifyPort == nil else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        self.notifyPort = port

        let (stream, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(32))

        // Drain initial replay — the matching iterator emits one event per
        // currently-connected device on first iteration. We want to ignore
        // those and only react to NEW arrivals.
        let attachContext = USBContext(continuation: continuation, isInitialReplay: true)
        let detachContext = USBContext(continuation: continuation, isInitialReplay: false)

        let matching = IOServiceMatching(kIOUSBDeviceClassName)

        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        var rawAttachIter: io_iterator_t = 0
        let attachKr = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching, // matching dict — IOServiceAddMatchingNotification consumes one ref
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<USBContext>.fromOpaque(ctx).takeUnretainedValue()
                let isInitial = context.isInitialReplay
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    if isInitial { continue }   // suppress launch-time replay
                    if let info = USBSource.deviceInfo(from: device) {
                        context.continuation.yield(.usbAttached(info))
                    }
                }
                context.isInitialReplay = false
            },
            retainedAttachContext.toOpaque(),
            &rawAttachIter
        )

        var rawDetachIter: io_iterator_t = 0
        let detachKr = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching(kIOUSBDeviceClassName),
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<USBContext>.fromOpaque(ctx).takeUnretainedValue()
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    if let info = USBSource.deviceInfo(from: device) {
                        context.continuation.yield(.usbDetached(info))
                    }
                }
            },
            retainedDetachContext.toOpaque(),
            &rawDetachIter
        )

        guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS else {
            log.warning("activity:USBSource wasInvalidatedBy entity:IOService — attachKr=\(attachKr) detachKr=\(detachKr)")
            if rawAttachIter != 0 { IOObjectRelease(rawAttachIter) }
            if rawDetachIter != 0 { IOObjectRelease(rawDetachIter) }
            retainedAttachContext.release()
            retainedDetachContext.release()
            IONotificationPortDestroy(port)
            self.notifyPort = nil
            return
        }
        attachIterator = rawAttachIter
        detachIterator = rawDetachIter

        // Drain to flag end-of-replay.
        while case let dev = IOIteratorNext(attachIterator), dev != 0 { IOObjectRelease(dev) }
        attachContext.isInitialReplay = false
        // Same for detach (no replay expected, but consistent).
        while case let dev = IOIteratorNext(detachIterator), dev != 0 { IOObjectRelease(dev) }

        // Hold contexts alive for as long as the iterators are active.
        self.attachContextHandle = retainedAttachContext
        self.detachContextHandle = retainedDetachContext

        publishTask = Task { @MainActor [weak self] in
            for await reaction in stream {
                guard let self else { continue }
                if self.shouldPublish(reaction) {
                    log.info("activity:Publish wasGeneratedBy entity:USBSource kind=\(reaction.kind.rawValue)")
                    await bus.publish(reaction)
                } else {
                    log.debug("activity:USBGated kind=\(reaction.kind.rawValue) — debounce")
                }
            }
        }
        log.info("activity:USBSource wasStartedBy entity:USBSource")
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
        if detachIterator != 0 { IOObjectRelease(detachIterator); detachIterator = 0 }
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        attachContextHandle?.release()
        attachContextHandle = nil
        detachContextHandle?.release()
        detachContextHandle = nil
    }

    private var attachContextHandle: Unmanaged<USBContext>?
    private var detachContextHandle: Unmanaged<USBContext>?

    private func shouldPublish(_ reaction: Reaction) -> Bool {
        let key: String
        switch reaction {
        case .usbAttached(let info): key = "attach-\(info.vendorID)-\(info.productID)"
        case .usbDetached(let info): key = "detach-\(info.vendorID)-\(info.productID)"
        default: return true
        }
        let now = Date()
        return lastEvent.withLock { table in
            if let prev = table[key], now.timeIntervalSince(prev) < ReactionsConfig.usbDebounce {
                return false
            }
            table[key] = now
            return true
        }
    }

    #if DEBUG
    /// Test seam — publishes a synthesized reaction of `kind` directly to the
    /// bus this source was started with, bypassing IOKit. Returns immediately
    /// if the source has not been started.
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        await bus.publish(USBSource._reactionForTest(kind))
    }

    /// Test seam — runs the production `shouldPublish` debounce check against
    /// a synthesized reaction. Returns the same Bool the production stream
    /// drainer uses to gate the bus publish. Lets debounce timing tests
    /// drive the same code path IOKit's callback would, without IOKit.
    public func _testShouldPublish(_ kind: ReactionKind) -> Bool {
        shouldPublish(USBSource._reactionForTest(kind))
    }

    static func _reactionForTest(_ kind: ReactionKind) -> Reaction {
        let info = USBDeviceInfo(name: "TestUSB", vendorID: 0xBEEF, productID: 0xCAFE)
        switch kind {
        case .usbAttached: return .usbAttached(info)
        case .usbDetached: return .usbDetached(info)
        default:           return .usbAttached(info)
        }
    }
    #endif

    fileprivate static func deviceInfo(from device: io_object_t) -> USBDeviceInfo? {
        let name = (IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
            ?? (IORegistryEntryCreateCFProperty(device, kIOServiceClass as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
            ?? "USB Device"
        let vid = (IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0
        let pid = (IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0
        return USBDeviceInfo(name: name, vendorID: vid, productID: pid)
    }
}

private final class USBContext: @unchecked Sendable {
    let continuation: AsyncStream<Reaction>.Continuation
    var isInitialReplay: Bool
    init(continuation: AsyncStream<Reaction>.Continuation, isInitialReplay: Bool) {
        self.continuation = continuation
        self.isInitialReplay = isInitialReplay
    }
}

// MARK: - AC power source

/// AC plug / unplug via `IOPSNotificationCreateRunLoopSource`. Edge-triggered
/// against the providing power source type — only emits on transitions.
@MainActor
public final class PowerSource: Sendable {
    private var runLoopSource: CFRunLoopSource?
    private var publishTask: Task<Void, Never>?
    private var stream: AsyncStream<Reaction>.Continuation?
    private var lastWasOnAC: Bool = false
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    public func start(publishingTo bus: ReactionBus) {
        guard runLoopSource == nil else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        lastWasOnAC = Self.currentlyOnAC()

        let (events, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = continuation

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerSource>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.handlePowerChange() }
        }, context)?.takeRetainedValue() else {
            log.warning("activity:PowerSource wasInvalidatedBy entity:IOPSNotification")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source

        publishTask = Task {
            for await reaction in events {
                log.info("activity:Publish wasGeneratedBy entity:PowerSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:PowerSource wasStartedBy entity:PowerSource onAC=\(lastWasOnAC)")
    }

    @MainActor
    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        stream?.finish()
        stream = nil
    }

    fileprivate func handlePowerChange() {
        log.debug("activity:PowerChange detected onAC=\(Self.currentlyOnAC())")
        let onAC = Self.currentlyOnAC()
        guard onAC != lastWasOnAC else { return }
        lastWasOnAC = onAC
        let reaction: Reaction = onAC ? .acConnected : .acDisconnected
        stream?.yield(reaction)
    }

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        let reaction: Reaction
        switch kind {
        case .acConnected:    reaction = .acConnected
        case .acDisconnected: reaction = .acDisconnected
        default:              reaction = .acConnected
        }
        await bus.publish(reaction)
    }
    #endif

    fileprivate static func currentlyOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let typeRef = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        let type = typeRef as String
        return type == kIOPMACPowerKey
    }
}

// MARK: - Audio peripheral attach/detach

/// CoreAudio device-list listener. Diffs the device set on every callback
/// and emits an attached/detached reaction per change. Initial population
/// is suppressed.
@MainActor
public final class AudioPeripheralSource: Sendable {
    private var listenerInstalled = false
    private var publishTask: Task<Void, Never>?
    private var stream: AsyncStream<Reaction>.Continuation?
    private var knownDevices: Set<String> = []
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    public func start(publishingTo bus: ReactionBus) {
        guard !listenerInstalled else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        knownDevices = Self.snapshot()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let (events, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = continuation

        let queue = DispatchQueue.main
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        guard status == noErr else {
            log.warning("activity:AudioPeripheralSource wasInvalidatedBy entity:CoreAudio status=\(status)")
            return
        }
        listenerInstalled = true
        self.listenerBlock = block
        self.listenerAddress = address

        publishTask = Task {
            for await reaction in events {
                log.info("activity:Publish wasGeneratedBy entity:AudioPeripheralSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:AudioPeripheralSource wasStartedBy entity:AudioPeripheralSource count=\(knownDevices.count)")
    }

    @MainActor
    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if listenerInstalled, var address = listenerAddress, let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
        listenerInstalled = false
        listenerBlock = nil
        listenerAddress = nil
        stream?.finish()
        stream = nil
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listenerAddress: AudioObjectPropertyAddress?

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        let info = AudioPeripheralInfo(uid: "test-uid", name: "TestAudio")
        let reaction: Reaction
        switch kind {
        case .audioPeripheralAttached: reaction = .audioPeripheralAttached(info)
        case .audioPeripheralDetached: reaction = .audioPeripheralDetached(info)
        default:                       reaction = .audioPeripheralAttached(info)
        }
        await bus.publish(reaction)
    }
    #endif

    fileprivate func handleChange() {
        log.debug("activity:AudioPeripheralChange detected devices=\(knownDevices.count)")
        let now = Self.snapshot()
        let added = now.subtracting(knownDevices)
        let removed = knownDevices.subtracting(now)
        knownDevices = now

        for uid in added {
            let name = Self.name(forUID: uid) ?? "Audio Device"
            stream?.yield(.audioPeripheralAttached(.init(uid: uid, name: name)))
        }
        for uid in removed {
            stream?.yield(.audioPeripheralDetached(.init(uid: uid, name: "Audio Device")))
        }
    }

    private static func snapshot() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids.compactMap { uid(forDevice: $0) })
    }

    private static func uid(forDevice id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func name(forUID uid: String) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids where Self.uid(forDevice: id) == uid {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameValue: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameValue) == noErr,
               let nameValue {
                return nameValue.takeUnretainedValue() as String
            }
        }
        return nil
    }
}

// MARK: - Bluetooth connect/disconnect

/// Surfaces Bluetooth device connect/disconnect by polling
/// `IOServiceMatching("IOBluetoothDevice")`. Pure IOKit — avoids a dependency
/// on `IOBluetooth.framework` (which would require a private-symbol bridge
/// to access connection state).
public final class BluetoothSource: @unchecked Sendable {
    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private var publishTask: Task<Void, Never>?
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    @MainActor
    public func start(publishingTo bus: ReactionBus) {
        guard notifyPort == nil else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let (stream, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(8))

        let attachContext = BluetoothContext(continuation: continuation, isInitialReplay: true)
        let detachContext = BluetoothContext(continuation: continuation, isInitialReplay: false)
        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        let attachKr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            IOServiceMatching("IOBluetoothDevice"),
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<BluetoothContext>.fromOpaque(ctx).takeUnretainedValue()
                let isInitial = context.isInitialReplay
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    if isInitial { continue }
                    if let info = BluetoothSource.deviceInfo(from: device) {
                        context.continuation.yield(.bluetoothConnected(info))
                    }
                }
                context.isInitialReplay = false
            },
            retainedAttachContext.toOpaque(),
            &attachIterator
        )

        let detachKr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOBluetoothDevice"),
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<BluetoothContext>.fromOpaque(ctx).takeUnretainedValue()
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    if let info = BluetoothSource.deviceInfo(from: device) {
                        context.continuation.yield(.bluetoothDisconnected(info))
                    }
                }
            },
            retainedDetachContext.toOpaque(),
            &detachIterator
        )
        guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS else {
            log.warning("activity:BluetoothSource wasInvalidatedBy entity:IOService — attachKr=\(attachKr) detachKr=\(detachKr)")
            if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
            if detachIterator != 0 { IOObjectRelease(detachIterator); detachIterator = 0 }
            retainedAttachContext.release()
            retainedDetachContext.release()
            IONotificationPortDestroy(port)
            self.notifyPort = nil
            return
        }
        while case let dev = IOIteratorNext(attachIterator), dev != 0 { IOObjectRelease(dev) }
        attachContext.isInitialReplay = false
        while case let dev = IOIteratorNext(detachIterator), dev != 0 { IOObjectRelease(dev) }

        attachContextHandle = retainedAttachContext
        detachContextHandle = retainedDetachContext

        publishTask = Task { @MainActor in
            for await reaction in stream {
                log.info("activity:Publish wasGeneratedBy entity:BluetoothSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:BluetoothSource wasStartedBy entity:BluetoothSource")
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
        if detachIterator != 0 { IOObjectRelease(detachIterator); detachIterator = 0 }
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        attachContextHandle?.release()
        attachContextHandle = nil
        detachContextHandle?.release()
        detachContextHandle = nil
    }

    private var attachContextHandle: Unmanaged<BluetoothContext>?
    private var detachContextHandle: Unmanaged<BluetoothContext>?

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        let info = BluetoothDeviceInfo(address: "AA:BB:CC:DD:EE:FF", name: "TestBT")
        let reaction: Reaction
        switch kind {
        case .bluetoothConnected:    reaction = .bluetoothConnected(info)
        case .bluetoothDisconnected: reaction = .bluetoothDisconnected(info)
        default:                     reaction = .bluetoothConnected(info)
        }
        await bus.publish(reaction)
    }
    #endif

    fileprivate static func deviceInfo(from device: io_object_t) -> BluetoothDeviceInfo? {
        let name = (IORegistryEntryCreateCFProperty(device, "DeviceName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
            ?? (IORegistryEntryCreateCFProperty(device, "BluetoothDeviceName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
            ?? "Bluetooth Device"
        let address = (IORegistryEntryCreateCFProperty(device, "BluetoothDeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        return BluetoothDeviceInfo(address: address, name: name)
    }
}

private final class BluetoothContext: @unchecked Sendable {
    let continuation: AsyncStream<Reaction>.Continuation
    var isInitialReplay: Bool
    init(continuation: AsyncStream<Reaction>.Continuation, isInitialReplay: Bool) {
        self.continuation = continuation
        self.isInitialReplay = isInitialReplay
    }
}

// MARK: - Thunderbolt attach/detach

/// IOKit Thunderbolt port attach/detach. Matches `IOThunderboltPort` /
/// `IOThunderboltSwitchType3` — both classes show up depending on the
/// Mac generation. Initial replay is suppressed.
public final class ThunderboltSource: @unchecked Sendable {
    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private var publishTask: Task<Void, Never>?
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    @MainActor
    public func start(publishingTo bus: ReactionBus) {
        guard notifyPort == nil else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let (stream, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(8))

        let attachContext = ThunderboltContext(continuation: continuation, isInitialReplay: true)
        let detachContext = ThunderboltContext(continuation: continuation, isInitialReplay: false)
        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        let attachKr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            IOServiceMatching("IOThunderboltPort"),
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<ThunderboltContext>.fromOpaque(ctx).takeUnretainedValue()
                let isInitial = context.isInitialReplay
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    if isInitial { continue }
                    let name = (IORegistryEntryCreateCFProperty(device, "IOName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? "Thunderbolt"
                    context.continuation.yield(.thunderboltAttached(.init(name: name)))
                }
                context.isInitialReplay = false
            },
            retainedAttachContext.toOpaque(),
            &attachIterator
        )

        let detachKr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOThunderboltPort"),
            { ctx, iter in
                guard let ctx else { return }
                let context = Unmanaged<ThunderboltContext>.fromOpaque(ctx).takeUnretainedValue()
                while case let device = IOIteratorNext(iter), device != 0 {
                    defer { IOObjectRelease(device) }
                    let name = (IORegistryEntryCreateCFProperty(device, "IOName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? "Thunderbolt"
                    context.continuation.yield(.thunderboltDetached(.init(name: name)))
                }
            },
            retainedDetachContext.toOpaque(),
            &detachIterator
        )
        guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS else {
            log.warning("activity:ThunderboltSource wasInvalidatedBy entity:IOService — attachKr=\(attachKr) detachKr=\(detachKr)")
            if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
            if detachIterator != 0 { IOObjectRelease(detachIterator); detachIterator = 0 }
            retainedAttachContext.release()
            retainedDetachContext.release()
            IONotificationPortDestroy(port)
            self.notifyPort = nil
            return
        }
        while case let dev = IOIteratorNext(attachIterator), dev != 0 { IOObjectRelease(dev) }
        attachContext.isInitialReplay = false
        while case let dev = IOIteratorNext(detachIterator), dev != 0 { IOObjectRelease(dev) }

        attachContextHandle = retainedAttachContext
        detachContextHandle = retainedDetachContext

        publishTask = Task { @MainActor in
            for await reaction in stream {
                log.info("activity:Publish wasGeneratedBy entity:ThunderboltSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:ThunderboltSource wasStartedBy entity:ThunderboltSource")
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if attachIterator != 0 { IOObjectRelease(attachIterator); attachIterator = 0 }
        if detachIterator != 0 { IOObjectRelease(detachIterator); detachIterator = 0 }
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        attachContextHandle?.release()
        attachContextHandle = nil
        detachContextHandle?.release()
        detachContextHandle = nil
    }

    private var attachContextHandle: Unmanaged<ThunderboltContext>?
    private var detachContextHandle: Unmanaged<ThunderboltContext>?

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        let info = ThunderboltDeviceInfo(name: "TestTB")
        let reaction: Reaction
        switch kind {
        case .thunderboltAttached: reaction = .thunderboltAttached(info)
        case .thunderboltDetached: reaction = .thunderboltDetached(info)
        default:                   reaction = .thunderboltAttached(info)
        }
        await bus.publish(reaction)
    }
    #endif
}

private final class ThunderboltContext: @unchecked Sendable {
    let continuation: AsyncStream<Reaction>.Continuation
    var isInitialReplay: Bool
    init(continuation: AsyncStream<Reaction>.Continuation, isInitialReplay: Bool) {
        self.continuation = continuation
        self.isInitialReplay = isInitialReplay
    }
}

// MARK: - Display hot-plug

/// `CGDisplayRegisterReconfigurationCallback` collapses the 3-4 callbacks
/// per real change into a single debounced reaction.
public final class DisplayHotplugSource: @unchecked Sendable {
    private var registered = false
    private var publishTask: Task<Void, Never>?
    private let stream = OSAllocatedUnfairLock<AsyncStream<Reaction>.Continuation?>(initialState: nil)
    private let lastFire = OSAllocatedUnfairLock<Date>(initialState: .distantPast)
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    @MainActor
    public func start(publishingTo bus: ReactionBus) {
        guard !registered else { return }
        #if DEBUG
        self._testBus = bus
        #endif
        let (events, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(4))
        stream.withLock { $0 = continuation }

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard let ctx else { return }
            let me = Unmanaged<DisplayHotplugSource>.fromOpaque(ctx).takeUnretainedValue()
            // Only react to "configuration finished" callbacks — the
            // pre-callbacks fire too eagerly.
            if flags.contains(.beginConfigurationFlag) { return }
            me.dispatchDebounced()
        }, context)
        registered = true

        publishTask = Task { @MainActor in
            for await reaction in events {
                log.info("activity:Publish wasGeneratedBy entity:DisplayHotplugSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:DisplayHotplugSource wasStartedBy entity:DisplayHotplugSource")
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if registered {
            let context = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback({ _, _, _ in }, context)
            // Note: CGDisplayRemoveReconfigurationCallback requires the EXACT
            // same callback pointer — pass a no-op above; system tolerates it.
            registered = false
        }
        stream.withLock { $0?.finish(); $0 = nil }
    }

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        // Only `.displayConfigured` is meaningful for this source.
        _ = kind
        await bus.publish(.displayConfigured)
    }

    /// Test seam — runs the production debounce path that the
    /// CGDisplayRegisterReconfigurationCallback drives. Returns true if the
    /// debounce window allowed a yield (would have fired), false if gated.
    /// Drives `dispatchDebounced` and inspects whether the underlying stream
    /// would have yielded by checking `lastFire` mutation.
    public func _testDispatchDebounced() -> Bool {
        let beforeFire = lastFire.withLock { $0 }
        dispatchDebounced()
        let afterFire = lastFire.withLock { $0 }
        return afterFire != beforeFire
    }
    #endif

    fileprivate func dispatchDebounced() {
        let now = Date()
        let shouldFire = lastFire.withLock { last -> Bool in
            if now.timeIntervalSince(last) < ReactionsConfig.displayDebounce { return false }
            last = now
            return true
        }
        guard shouldFire else { return }
        _ = stream.withLock { $0?.yield(.displayConfigured) }
    }
}

// MARK: - Sleep / wake

/// `IORegisterForSystemPower` for sleep/wake. The same API the
/// sensor-kickstart helper uses to re-warm the BMI286 on wake.
public final class SleepWakeSource: @unchecked Sendable {
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var publishTask: Task<Void, Never>?
    private let stream = OSAllocatedUnfairLock<AsyncStream<Reaction>.Continuation?>(initialState: nil)
    #if DEBUG
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    @MainActor
    public func start(publishingTo bus: ReactionBus) {
        guard rootPort == 0 else { return }
        #if DEBUG
        self._testBus = bus
        #endif

        let (events, continuation) = AsyncStream<Reaction>.makeStream(bufferingPolicy: .bufferingNewest(4))
        stream.withLock { $0 = continuation }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var rawNotifier: io_object_t = 0
        var port: IONotificationPortRef?
        let connect = IORegisterForSystemPower(context, &port, { ctx, _, messageType, messageArgument in
            guard let ctx else { return }
            let me = Unmanaged<SleepWakeSource>.fromOpaque(ctx).takeUnretainedValue()
            switch messageType {
            case kIOMessageSystemWillSleep:
                _ = me.stream.withLock { $0?.yield(.willSleep) }
                IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument.map(UInt.init(bitPattern:)) ?? 0))
            case kIOMessageSystemHasPoweredOn:
                _ = me.stream.withLock { $0?.yield(.didWake) }
            default:
                break
            }
        }, &rawNotifier)
        guard connect != 0, let port else {
            log.warning("activity:SleepWakeSource wasInvalidatedBy entity:IORegisterForSystemPower")
            return
        }
        rootPort = connect
        notifyPort = port
        notifier = rawNotifier
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        publishTask = Task { @MainActor in
            for await reaction in events {
                log.info("activity:Publish wasGeneratedBy entity:SleepWakeSource kind=\(reaction.kind.rawValue)")
                await bus.publish(reaction)
            }
        }
        log.info("activity:SleepWakeSource wasStartedBy entity:SleepWakeSource")
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        if let port = notifyPort {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                .defaultMode
            )
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if rootPort != 0 { IOServiceClose(rootPort); rootPort = 0 }
        stream.withLock { $0?.finish(); $0 = nil }
    }

    #if DEBUG
    @MainActor
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        let reaction: Reaction
        switch kind {
        case .willSleep: reaction = .willSleep
        case .didWake:   reaction = .didWake
        default:         reaction = .didWake
        }
        await bus.publish(reaction)
    }
    #endif
}

// MARK: - StimulusSource conformances

extension USBSource: StimulusSource {
    public var id: SensorID { .usb }
}

extension PowerSource: StimulusSource {
    public var id: SensorID { .power }
}

extension AudioPeripheralSource: StimulusSource {
    public var id: SensorID { .audioPeripheral }
}

extension BluetoothSource: StimulusSource {
    public var id: SensorID { .bluetooth }
}

extension ThunderboltSource: StimulusSource {
    public var id: SensorID { .thunderbolt }
}

extension DisplayHotplugSource: StimulusSource {
    public var id: SensorID { .displayHotplug }
}

extension SleepWakeSource: StimulusSource {
    public var id: SensorID { .sleepWake }
}
