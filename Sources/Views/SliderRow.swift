import SwiftUI

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    var tooltip: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Theme.sectionHeader(label, help: tooltip)
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .tint(Theme.pink)
                Text(display)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}
