import SwiftUI

// MARK: - Sensitivity ruler

internal struct SensitivityRuler: View {
    /// One tick on the sensitivity ruler. `position` is a unit-interval
    /// fraction (0.0 = leftmost, 1.0 = rightmost) and gets multiplied by
    /// the GeometryReader width at render time. `label` is a localized
    /// short string (e.g. "Hard", "Firm", "Medium").
    internal struct Tick: Equatable {
        let position: Double
        let label: String
    }

    /// Five tick marks pinning the impact-tier scale: Hard / Firm /
    /// Medium / Light / Tap. Promoted to `internal` so unit tests can
    /// assert array length, ordering, position bounds, and the localized
    /// label keys without bitmap-fingerprinting the rendered view.
    internal static let ticks: [Tick] = [
        Tick(position: 0.0,  label: NSLocalizedString("tier_hard", comment: "Ruler label: hardest impact")),
        Tick(position: 0.25, label: NSLocalizedString("tier_firm", comment: "Ruler label: firm impact")),
        Tick(position: 0.50, label: NSLocalizedString("tier_medium", comment: "Ruler label: medium impact (abbreviated)")),
        Tick(position: 0.75, label: NSLocalizedString("tier_light", comment: "Ruler label: light impact")),
        Tick(position: 1.0,  label: NSLocalizedString("tier_tap", comment: "Ruler label: lightest impact")),
    ]

    /// Per-tick horizontal placement formula. Pulled out as a static so
    /// unit tests can drive the math directly without rendering the view.
    /// Mutating the multiplication (e.g. dividing instead) makes ticks
    /// pile up at the origin and the cell's pinned values fail.
    internal static func position(for tick: Tick, in width: Double) -> Double {
        tick.position * width
    }

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
                    .position(x: Self.position(for: tick, in: w), y: 8)
                }
            }
            .frame(height: 16)
            Spacer().frame(width: 50)
        }
    }
}
