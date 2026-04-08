import SwiftUI

struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    var labelWidth: CGFloat = 40
    let format: (Double) -> String

    private let thumbW: CGFloat = 22
    private let thumbH: CGFloat = 17
    private let trackH: CGFloat = 4
    private static let coordSpace = "rangeSlider"

    @State private var activeThumb: ActiveThumb = .none

    private enum ActiveThumb { case none, low, high }

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
                            let x = v.location.x

                            if activeThumb == .none {
                                let distLow  = abs(x - lowX)
                                let distHigh = abs(x - highX)

                                if abs(lowX - highX) < 2 {
                                    let dx = v.translation.width
                                    activeThumb = dx >= 0 ? .high : .low
                                } else {
                                    activeThumb = distLow <= distHigh ? .low : .high
                                }
                            }

                            let clamped = min(max(half, x), half + usable)
                            let value = bounds.lowerBound + Double((clamped - half) / usable) * span

                            switch activeThumb {
                            case .low:
                                if value > high {
                                    low = high
                                    high = value
                                    activeThumb = .high
                                } else {
                                    low = value
                                }
                            case .high:
                                if value < low {
                                    high = low
                                    low = value
                                    activeThumb = .low
                                } else {
                                    high = value
                                }
                            case .none:
                                break
                            }
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
