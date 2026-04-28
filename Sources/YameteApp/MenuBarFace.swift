#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import AppKit
import Foundation
import Observation

/// Menu-bar reaction face. Subscribes to the bus, swaps `NSStatusItem`'s
/// icon to one of the cached face images for the duration of an impact,
/// then restores the template icon. Independent of `visualResponseMode` —
/// the menu bar face is the always-on visual feedback channel.
@MainActor @Observable
public final class MenuBarFace {
    public private(set) var reactionFace: NSImage?
    public private(set) var lastImpactMagnitude: Float = 0
    public var lastImpactTier: ImpactTier? { lastImpactMagnitude > 0 ? ImpactTier.from(intensity: lastImpactMagnitude) : nil }
    public private(set) var impactCount: Int = 0

    private var consumeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var countDate: Date = Calendar.current.startOfDay(for: Date())

    public init() {}

    /// Subscribes to the bus. Only `.impact` reactions trigger a face swap;
    /// events do not. Call once at app launch.
    public func consume(from bus: ReactionBus, debounceProvider: @escaping @MainActor () -> Double) {
        consumeTask?.cancel()
        consumeTask = Task { @MainActor [weak self] in
            let stream = await bus.subscribe()
            for await fired in stream {
                guard let self else { return }
                guard case .impact(let fused) = fired.reaction else { continue }
                self.show(intensity: fused.intensity, faceIndex: fired.faceIndices.first ?? 0, duration: max(0.5, debounceProvider()))
                self.recordCount(at: fused.timestamp)
            }
        }
    }

    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        hideTask?.cancel()
        hideTask = nil
        reactionFace = nil
    }

    private func show(intensity: Float, faceIndex: Int, duration: Double) {
        guard let face = FaceLibrary.shared.image(at: faceIndex) else { return }
        face.size = NSSize(width: 18, height: 18)
        reactionFace = face
        lastImpactMagnitude = intensity

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.reactionFace = nil
        }
    }


    private func recordCount(at timestamp: Date) {
        let today = Calendar.current.startOfDay(for: timestamp)
        if today > countDate { impactCount = 0; countDate = today }
        impactCount += 1
    }
}
