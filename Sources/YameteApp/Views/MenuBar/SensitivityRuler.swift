import SwiftUI

// MARK: - Sensitivity ruler

internal struct SensitivityRuler: View {
    private static let ticks: [(position: Double, label: String)] = [
        (0.0, NSLocalizedString("tier_hard", comment: "Ruler label: hardest impact")),
        (0.25, NSLocalizedString("tier_firm", comment: "Ruler label: firm impact")),
        (0.50, NSLocalizedString("tier_medium", comment: "Ruler label: medium impact (abbreviated)")),
        (0.75, NSLocalizedString("tier_light", comment: "Ruler label: light impact")),
        (1.0, NSLocalizedString("tier_tap", comment: "Ruler label: lightest impact")),
    ]

    public var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 50)
            GeometryReader { geo in
                let w = geo.size.width
                ForEach(Array(Self.ticks.enumerated()), id: \.offset) { _, tick in
                    VStack(spacing: 1) {
                        Text(tick.label).font(.system(size: 8)).foregroundStyle(.tertiary)
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 4)
                    }
                    .position(x: tick.position * w, y: 8)
                }
            }
            .frame(height: 16)
            Spacer().frame(width: 50)
        }
    }
}
