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
    /// Continuation of the AsyncStream the IOKit callbacks yield into. Stored
    /// so the test-seam injectors can yield through the same drainer path
    /// (which runs `shouldPublish` debounce and forwards to the bus).
    private var streamContinuation: AsyncStream<Reaction>.Continuation?
    #if DEBUG
    /// Weak ref to the bus, set on `start`. Used by `_testEmit` and the
    /// IOKit-callback test seams (`_injectAttach` / `_injectDetach`) to drive
    /// the same publish path the production stream drainer drives.
    private weak var _testBus: ReactionBus?
    /// Test seam — forces both `IOServiceAddMatchingNotification` returns to the supplied non-success kernel result so the kernel-success guard fires. Production-default nil → real returns propagated.
    internal var _forceKernelFailureKr: kern_return_t?
    /// Test seam — increments after each successful registration of IOKit notifications. Idempotency cells call `start()` twice; expect 1.
    internal var _testInstallationCount: Int = 0
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
        self.streamContinuation = continuation

        // Drain initial replay — the matching iterator emits one event per
        // currently-connected device on first iteration. We want to ignore
        // those and only react to NEW arrivals.
        let attachContext = USBContext(continuation: continuation, isInitialReplay: true)
        let detachContext = USBContext(continuation: continuation, isInitialReplay: false)

        let matching = IOServiceMatching(kIOUSBDeviceClassName)

        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        var rawAttachIter: io_iterator_t = 0
        var attachKr = IOServiceAddMatchingNotification(
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
        var detachKr = IOServiceAddMatchingNotification(
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
        #if DEBUG
        if let forced = _forceKernelFailureKr { attachKr = forced; detachKr = forced }
        #endif

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
        #if DEBUG
        _testInstallationCount += 1
        #endif

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
        streamContinuation?.finish()
        streamContinuation = nil
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

    /// Test seam: mirrors the production `IOServiceAddMatchingNotification`
    /// callback that IOKit invokes for `kIOFirstMatchNotification`. Bypasses
    /// the kernel hop — pre-resolved vendor/product strings are passed in
    /// instead of having IOKit traverse an `io_iterator_t`. Yields into the
    /// same `AsyncStream` the production callback yields into, so the same
    /// `shouldPublish` debounce and `bus.publish` fan-out runs.
    /// `at:` is accepted for parity with the real callback's event time but
    /// the production debounce uses wall-clock time — tests that need
    /// timing-sensitive cells should sleep between calls.
    @MainActor
    public func _injectAttach(vendor: String, product: String, at timestamp: Date = Date()) async {
        _ = timestamp
        let info = USBDeviceInfo(name: product, vendorID: vendor.hashValue, productID: product.hashValue)
        streamContinuation?.yield(.usbAttached(info))
        // Yield to let the publishTask drainer pick it up, run shouldPublish,
        // and forward to the bus before the test inspects the bus.
        await Task.yield()
    }

    /// Test seam: mirrors the `kIOTerminatedNotification` callback path.
    @MainActor
    public func _injectDetach(vendor: String, product: String, at timestamp: Date = Date()) async {
        _ = timestamp
        let info = USBDeviceInfo(name: product, vendorID: vendor.hashValue, productID: product.hashValue)
        streamContinuation?.yield(.usbDetached(info))
        await Task.yield()
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
        let onAC = Self.currentlyOnAC()
        log.debug("activity:PowerChange detected onAC=\(onAC)")
        handlePowerChange(onAC: onAC)
    }

    /// Edge-triggered against `lastWasOnAC` — only emits on AC-state
    /// transitions. Called from the `IOPSNotificationCreateRunLoopSource`
    /// callback path with the current system state, and from the
    /// `_injectPowerChange` test seam with a synthetic state.
    fileprivate func handlePowerChange(onAC: Bool) {
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

    /// Test seam: mirrors the `IOPSNotificationCreateRunLoopSource` callback
    /// that fires when the system AC state changes. Bypasses the IOKit hop
    /// AND `IOPSCopyPowerSourcesInfo` — the test passes the synthetic AC
    /// state directly. Drives the same `handlePowerChange(onAC:)` edge-trigger
    /// path the production callback drives.
    @MainActor
    public func _injectPowerChange(onAC: Bool, at timestamp: Date = Date()) async {
        _ = timestamp
        handlePowerChange(onAC: onAC)
        await Task.yield()
    }

    /// Test seam: exposes the host's current AC state (the same value
    /// `start()` uses to seed `lastWasOnAC`). Lets tests determine the
    /// baseline so they can construct deterministic-edge inject sequences
    /// regardless of whether the host is actually plugged in.
    public static func _currentlyOnAC() -> Bool { Self.currentlyOnAC() }
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
    /// Test seam — forces `AudioObjectAddPropertyListenerBlock`'s `OSStatus` to non-noErr so the kernel-success guard fires. Production nil = real.
    internal var _forceListenerStatus: OSStatus?
    /// Test seam — increments after each successful listener install.
    internal var _testInstallationCount: Int = 0
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
        var status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        #if DEBUG
        if let forced = _forceListenerStatus {
            // Tear down real listener so the override leaves no leak.
            if status == noErr {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, block
                )
            }
            status = forced
        }
        #endif
        guard status == noErr else {
            log.warning("activity:AudioPeripheralSource wasInvalidatedBy entity:CoreAudio status=\(status)")
            return
        }
        listenerInstalled = true
        self.listenerBlock = block
        self.listenerAddress = address
        #if DEBUG
        _testInstallationCount += 1
        #endif

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

    /// Test seam: mirrors the `AudioObjectAddPropertyListenerBlock` callback
    /// that fires when CoreAudio's device set changes. Bypasses the
    /// `Self.snapshot()` system query — the test passes the synthetic device
    /// `uid` and resolved `name` directly. Adds the uid to the tracked set
    /// and runs the production `handleChange(newDevices:names:)` diff,
    /// publishing exactly one `.audioPeripheralAttached` if the uid is new.
    @MainActor
    public func _injectAttach(uid: String, name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        var nextSet = knownDevices
        nextSet.insert(uid)
        handleChange(newDevices: nextSet, names: [uid: name])
        await Task.yield()
    }

    @MainActor
    public func _injectDetach(uid: String, name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        _ = name
        var nextSet = knownDevices
        nextSet.remove(uid)
        handleChange(newDevices: nextSet, names: [:])
        await Task.yield()
    }

    /// Test seam: seeds the `knownDevices` baseline so subsequent injects
    /// diff against a non-empty set. Mirrors the production `start()` snapshot.
    @MainActor
    public func _testSeedKnownDevices(_ uids: Set<String>) {
        knownDevices = uids
    }
    #endif

    fileprivate func handleChange() {
        log.debug("activity:AudioPeripheralChange detected devices=\(knownDevices.count)")
        let now = Self.snapshot()
        let names = Dictionary(uniqueKeysWithValues: now.map { uid in
            (uid, Self.name(forUID: uid) ?? "Audio Device")
        })
        handleChange(newDevices: now, names: names)
    }

    /// Diff-and-emit core. The CoreAudio property-listener block reads the
    /// current device set and forwards it through here; the test seam injects
    /// a synthetic set directly. `names` resolves a friendly name for each
    /// added UID — production reads them from the registry, tests pass them.
    fileprivate func handleChange(newDevices: Set<String>, names: [String: String]) {
        let added = newDevices.subtracting(knownDevices)
        let removed = knownDevices.subtracting(newDevices)
        knownDevices = newDevices

        for uid in added {
            let name = names[uid] ?? "Audio Device"
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
    /// Continuation of the AsyncStream the IOKit callbacks yield into. Stored
    /// so the test-seam injectors can yield through the same drainer path.
    private var streamContinuation: AsyncStream<Reaction>.Continuation?
    #if DEBUG
    private weak var _testBus: ReactionBus?
    /// Test seam — forces both `IOServiceAddMatchingNotification` kernel returns. Production-default nil = real returns propagated.
    internal var _forceKernelFailureKr: kern_return_t?
    /// Test seam — increments after each successful registration.
    internal var _testInstallationCount: Int = 0
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
        self.streamContinuation = continuation

        let attachContext = BluetoothContext(continuation: continuation, isInitialReplay: true)
        let detachContext = BluetoothContext(continuation: continuation, isInitialReplay: false)
        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        var attachKr = IOServiceAddMatchingNotification(
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

        var detachKr = IOServiceAddMatchingNotification(
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
        #if DEBUG
        if let forced = _forceKernelFailureKr { attachKr = forced; detachKr = forced }
        #endif
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
        #if DEBUG
        _testInstallationCount += 1
        #endif

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
        streamContinuation?.finish()
        streamContinuation = nil
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

    /// Test seam: mirrors the `IOServiceAddMatchingNotification` callback for
    /// `kIOFirstMatchNotification` on `IOBluetoothDevice`. Bypasses the
    /// `IORegistryEntryCreateCFProperty` lookup — the test passes a synthetic
    /// device name. Yields into the same AsyncStream the production callback
    /// yields into.
    @MainActor
    public func _injectConnect(name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        let info = BluetoothDeviceInfo(address: name, name: name)
        streamContinuation?.yield(.bluetoothConnected(info))
        await Task.yield()
    }

    @MainActor
    public func _injectDisconnect(name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        let info = BluetoothDeviceInfo(address: name, name: name)
        streamContinuation?.yield(.bluetoothDisconnected(info))
        await Task.yield()
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
    /// Continuation of the AsyncStream the IOKit callbacks yield into. Stored
    /// so the test-seam injectors can yield through the same drainer path.
    private var streamContinuation: AsyncStream<Reaction>.Continuation?
    #if DEBUG
    private weak var _testBus: ReactionBus?
    /// Test seam — forces both `IOServiceAddMatchingNotification` kernel returns. Production-default nil = real returns propagated.
    internal var _forceKernelFailureKr: kern_return_t?
    /// Test seam — increments after each successful registration.
    internal var _testInstallationCount: Int = 0
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
        self.streamContinuation = continuation

        let attachContext = ThunderboltContext(continuation: continuation, isInitialReplay: true)
        let detachContext = ThunderboltContext(continuation: continuation, isInitialReplay: false)
        let retainedAttachContext = Unmanaged.passRetained(attachContext)
        let retainedDetachContext = Unmanaged.passRetained(detachContext)

        var attachKr = IOServiceAddMatchingNotification(
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

        var detachKr = IOServiceAddMatchingNotification(
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
        #if DEBUG
        if let forced = _forceKernelFailureKr { attachKr = forced; detachKr = forced }
        #endif
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
        #if DEBUG
        _testInstallationCount += 1
        #endif

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
        streamContinuation?.finish()
        streamContinuation = nil
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

    /// Test seam: mirrors the `IOServiceAddMatchingNotification` callback for
    /// `kIOFirstMatchNotification` on `IOThunderboltPort`. Bypasses the
    /// `IORegistryEntryCreateCFProperty` lookup. Yields into the same
    /// AsyncStream the production callback yields into.
    @MainActor
    public func _injectAttach(name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        streamContinuation?.yield(.thunderboltAttached(.init(name: name)))
        await Task.yield()
    }

    @MainActor
    public func _injectDetach(name: String, at timestamp: Date = Date()) async {
        _ = timestamp
        streamContinuation?.yield(.thunderboltDetached(.init(name: name)))
        await Task.yield()
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
    /// Test seam — increments after each successful registration.
    internal var _testInstallationCount: Int = 0
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
        #if DEBUG
        _testInstallationCount += 1
        #endif

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

    /// Test seam: mirrors the `CGDisplayRegisterReconfigurationCallback`
    /// post-debounce path. Bypasses the kernel hop and the `flags`-gating
    /// (the production callback ignores `.beginConfigurationFlag` callbacks).
    /// Drives `dispatchDebounced` so the same 200ms window collapse applies
    /// to rapid-fire test injections that mirror real reconfigures.
    @MainActor
    public func _injectReconfigure(at timestamp: Date = Date()) async {
        _ = timestamp
        dispatchDebounced()
        await Task.yield()
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
    /// Test seam — forces `IORegisterForSystemPower` to be treated as failed so the kernel-success guard fires. Real resources allocated by the call are torn down before the override applies.
    internal var _forceRegistrationFailure: Bool = false
    /// Test seam — increments after each successful registration.
    internal var _testInstallationCount: Int = 0
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
        var connect = IORegisterForSystemPower(context, &port, { ctx, _, messageType, messageArgument in
            guard let ctx else { return }
            let me = Unmanaged<SleepWakeSource>.fromOpaque(ctx).takeUnretainedValue()
            switch messageType {
            case kIOMessageSystemWillSleep:
                me.handleWillSleep()
                // IOAllowPowerChange is a real-system call and only valid
                // when `rootPort` was registered against the kernel — the
                // test seam path skips this.
                IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument.map(UInt.init(bitPattern:)) ?? 0))
            case kIOMessageSystemHasPoweredOn:
                me.handleDidWake()
            default:
                break
            }
        }, &rawNotifier)
        #if DEBUG
        if _forceRegistrationFailure {
            // Force a connect=0 outcome; keep port non-nil so the
            // mutation-target sub-clause (`connect != 0`) is the SOLE
            // decider of whether the cleanup branch runs. Real resources
            // allocated by the call are torn down before the override
            // applies.
            if connect != 0 { IOServiceClose(connect); connect = 0 }
            if rawNotifier != 0 { IODeregisterForSystemPower(&rawNotifier); rawNotifier = 0 }
            if port == nil {
                // The kernel call yielded port=nil (rare but allowed); fabricate a dummy
                // so the let-port unwrap succeeds and only the connect != 0 sub-clause fails.
                port = IONotificationPortCreate(kIOMainPortDefault)
            }
        }
        #endif
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
        #if DEBUG
        _testInstallationCount += 1
        #endif

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

    /// Yields `.willSleep` to the AsyncStream the production publishTask
    /// drains. Called from the `IORegisterForSystemPower` callback path
    /// (alongside `IOAllowPowerChange` against the kernel rootPort) and
    /// from the `_injectWillSleep` test seam (without the kernel call).
    fileprivate func handleWillSleep() {
        _ = stream.withLock { $0?.yield(.willSleep) }
    }

    fileprivate func handleDidWake() {
        _ = stream.withLock { $0?.yield(.didWake) }
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

    /// Test seam: mirrors the `IORegisterForSystemPower` callback's
    /// `kIOMessageSystemWillSleep` path. Bypasses the kernel hop and the
    /// associated `IOAllowPowerChange(rootPort, ...)` reply (rootPort is 0
    /// in tests — calling it would be a no-op at best, undefined at worst).
    @MainActor
    public func _injectWillSleep(at timestamp: Date = Date()) async {
        _ = timestamp
        handleWillSleep()
        await Task.yield()
    }

    /// Test seam: mirrors the `kIOMessageSystemHasPoweredOn` path. The
    /// production callback does NOT call `IOAllowPowerChange` for wake (the
    /// kernel does not expect a reply), so this seam matches it exactly.
    /// Repeated `didWake` without an intervening `willSleep` is the system
    /// semantic — the source must not crash.
    @MainActor
    public func _injectDidWake(at timestamp: Date = Date()) async {
        _ = timestamp
        handleDidWake()
        await Task.yield()
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
