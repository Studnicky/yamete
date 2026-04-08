import SwiftUI

/// Single-value slider with the same custom track and thumb as RangeSlider.
/// Ensures identical visual width, alignment, and handle shape.
struct SingleSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double? = nil
    var labelWidth: CGFloat = 50
    let format: (Double) -> String

    private let thumbW: CGFloat = 22
    private let thumbH: CGFloat = 17
    private let trackH: CGFloat = 4
    private static let coordSpace = "singleSlider"

    var body: some View {
        HStack(spacing: 8) {
            Text(format(bounds.lowerBound))
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                sliderBody(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: thumbH)

            Text(format(value))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sliderBody(width w: CGFloat, height h: CGFloat) -> some View {
        let span = bounds.upperBound - bounds.lowerBound
        let yC = h / 2
        let safeW = max(w, 1)
        let half = thumbW / 2
        let usable = max(safeW - thumbW, 1)
        let ratio = CGFloat((value - bounds.lowerBound) / span).clamped(to: 0...1)
        let posX = half + ratio * usable

        ZStack {
            // Background track
            RoundedRectangle(cornerRadius: trackH / 2)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: trackH)

            // Filled track
            Path { p in
                p.move(to: .init(x: half, y: yC))
                p.addLine(to: .init(x: posX, y: yC))
            }
            .stroke(Theme.pink, lineWidth: trackH)

            // Thumb
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                .frame(width: thumbW, height: thumbH)
                .position(x: posX, y: yC)
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named(Self.coordSpace))
                        .onChanged { v in
                            let clamped = min(max(half, v.location.x), half + usable)
                            var raw = bounds.lowerBound + Double((clamped - half) / usable) * span
                            if let step { raw = (raw / step).rounded() * step }
                            value = raw.clamped(to: bounds)
                        }
                )
        }
        .coordinateSpace(name: Self.coordSpace)
    }
}

/// Integer variant with the same custom track.
struct SingleSliderInt: View {
    @Binding var value: Int
    let bounds: ClosedRange<Int>
    var labelWidth: CGFloat = 50
    let format: (Int) -> String

    @State private var doubleValue: Double = 0

    var body: some View {
        SingleSlider(
            value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ),
            bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
            step: 1,
            labelWidth: labelWidth,
            format: { format(Int($0.rounded())) }
        )
    }
}
