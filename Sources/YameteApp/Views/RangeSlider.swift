import SwiftUI

struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    var labelWidth: CGFloat = 40
    let format: (Double) -> String

    private let thumbD: CGFloat = 20
    private let trackH: CGFloat = 4
    private static let coordSpace = "rangeSlider"

    var body: some View {
        HStack(spacing: 8) {
            Text(format(low))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                sliderBody(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: thumbD)

            Text(format(high))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sliderBody(width w: CGFloat, height h: CGFloat) -> some View {
        let span  = bounds.upperBound - bounds.lowerBound
        let yC    = h / 2
        let safeW = max(w, 1)
        let lowX  = CGFloat((low  - bounds.lowerBound) / span).clamped(to: 0...1) * safeW
        let highX = CGFloat((high - bounds.lowerBound) / span).clamped(to: 0...1) * safeW

        ZStack {
            RoundedRectangle(cornerRadius: trackH / 2)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: trackH)

            Path { p in
                p.move(to:    .init(x: lowX,  y: yC))
                p.addLine(to: .init(x: highX, y: yC))
            }
            .stroke(Theme.pink, lineWidth: trackH)

            thumb().position(x: lowX, y: yC)
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named(Self.coordSpace))
                        .onChanged { v in
                            low = bounds.lowerBound + Double(min(max(0, v.location.x), highX - 1) / safeW) * span
                        }
                )

            thumb().position(x: highX, y: yC)
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named(Self.coordSpace))
                        .onChanged { v in
                            high = bounds.lowerBound + Double(min(max(lowX + 1, v.location.x), safeW) / safeW) * span
                        }
                )
        }
        .coordinateSpace(name: Self.coordSpace)
    }

    @ViewBuilder
    private func thumb() -> some View {
        Circle()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            .frame(width: thumbD, height: thumbD)
            .contentShape(Rectangle())
    }
}
