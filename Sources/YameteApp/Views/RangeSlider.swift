import SwiftUI

struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    var labelWidth: CGFloat = 40
    let format: (Double) -> String

    private let thumbW = Theme.sliderThumbWidth
    private let thumbH = Theme.sliderThumbHeight
    private let trackH = Theme.sliderTrackHeight
    private static let coordSpace = "rangeSlider"

    @State private var activeThumb: ActiveThumb = .none

    internal enum ActiveThumb { case none, low, high }

    /// Result of applying a single drag-tick to the (low, high, active) tuple.
    /// Captures the pair-swap branch that fires when the user drags one thumb
    /// past the other (low > high or high < low).
    internal struct DragResult: Equatable {
        let low: Double
        let high: Double
        let active: ActiveThumb
    }

    /// Pure-functional projection of the gestural math inside
    /// `DragGesture.onChanged`. Pulled out so unit tests can drive the
    /// clamp / pair-swap branches directly without pumping a synthetic
    /// `NSEvent` stream.
    ///
    /// - Parameters:
    ///   - locationX:   raw `v.location.x` from the gesture
    ///   - lowX:        rendered low-thumb x-position
    ///   - highX:       rendered high-thumb x-position
    ///   - translationWidth: `v.translation.width` (used for the
    ///                  overlap-disambiguation branch)
    ///   - half:        `thumbW / 2` — leading offset for the usable track
    ///   - usable:      width of the usable track region
    ///   - bounds:      value range
    ///   - low / high:  current thumb values
    ///   - active:      current `ActiveThumb`
    /// - Returns: the new (low, high, active) tuple after this tick.
    internal static func applyDrag(
        locationX: CGFloat,
        lowX: CGFloat,
        highX: CGFloat,
        translationWidth: CGFloat,
        half: CGFloat,
        usable: CGFloat,
        bounds: ClosedRange<Double>,
        low: Double,
        high: Double,
        active: ActiveThumb
    ) -> DragResult {
        var active = active
        let span = bounds.upperBound - bounds.lowerBound

        if active == .none {
            let distLow  = abs(locationX - lowX)
            let distHigh = abs(locationX - highX)

            if abs(lowX - highX) < 2 {
                active = translationWidth >= 0 ? .high : .low
            } else {
                active = distLow <= distHigh ? .low : .high
            }
        }

        let clamped = clamp(position: locationX, half: half, usable: usable)
        let value = bounds.lowerBound + Double((clamped - half) / usable) * span

        switch active {
        case .low:
            if value > high {
                return DragResult(low: high, high: value, active: .high)
            } else {
                return DragResult(low: value, high: high, active: .low)
            }
        case .high:
            if value < low {
                return DragResult(low: value, high: low, active: .low)
            } else {
                return DragResult(low: low, high: value, active: .high)
            }
        case .none:
            return DragResult(low: low, high: high, active: .none)
        }
    }

    /// Clamp a raw drag x-coordinate to the slider's usable track region
    /// `[half, half + usable]`. Pulled out so unit tests can drive the
    /// edge cases (overshoot left, overshoot right, inside) without
    /// rendering the view.
    internal static func clamp(position x: CGFloat, half: CGFloat, usable: CGFloat) -> CGFloat {
        min(max(half, x), half + usable)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(format(low))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                sliderBody(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: thumbH)

            Text(format(high))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sliderBody(width w: CGFloat, height h: CGFloat) -> some View {
        let span   = bounds.upperBound - bounds.lowerBound
        let yC     = h / 2
        let safeW  = max(w, 1)
        let half   = thumbW / 2
        let usable = max(safeW - thumbW, 1)
        let lowX   = half + CGFloat((low  - bounds.lowerBound) / span).clamped(to: 0...1) * usable
        let highX  = half + CGFloat((high - bounds.lowerBound) / span).clamped(to: 0...1) * usable

        ZStack {
            RoundedRectangle(cornerRadius: trackH / 2)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: trackH)

            Path { p in
                p.move(to:    .init(x: lowX,  y: yC))
                p.addLine(to: .init(x: highX, y: yC))
            }
            .stroke(Theme.pink, lineWidth: trackH)

            // Single gesture overlay handles both thumbs.
            // When thumbs overlap, drag direction picks which to move.
            Color.clear
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named(Self.coordSpace))
                        .onChanged { v in
                            let result = Self.applyDrag(
                                locationX: v.location.x,
                                lowX: lowX,
                                highX: highX,
                                translationWidth: v.translation.width,
                                half: half,
                                usable: usable,
                                bounds: bounds,
                                low: low,
                                high: high,
                                active: activeThumb
                            )
                            low = result.low
                            high = result.high
                            activeThumb = result.active
                        }
                        .onEnded { _ in
                            activeThumb = .none
                        }
                )

            thumb().position(x: lowX, y: yC)
                .allowsHitTesting(false)

            thumb().position(x: highX, y: yC)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: Self.coordSpace)
    }

    @ViewBuilder
    private func thumb() -> some View {
        Capsule()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            .frame(width: thumbW, height: thumbH)
    }
}
