import SwiftUI

/// Balanced grid layout for response-button rows.
///
/// For `N` enabled buttons, lays out `ceil(N / capPerRow)` rows distributed
/// as evenly as possible — smaller row(s) on top, larger row(s) on bottom.
/// Each row evenly subdivides the same container width, so the visual
/// "column rails" stay aligned: a 2+3 split gives 2 wide buttons on top
/// each occupying half the bottom row's three-button width. Heights are
/// uniform across rows (the global max intrinsic height of any subview).
///
/// Examples (`capPerRow = 4`):
/// - N=1..4 → one row.
/// - N=5    → 2 atop, 3 below.
/// - N=6    → 3 + 3.
/// - N=7    → 3 + 4.
/// - N=8    → 4 + 4.
/// - N=9    → 3 + 3 + 3.
/// - N=10   → 3 + 3 + 4.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var capPerRow: Int = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let counts = balancedRowCounts(total: subviews.count, cap: capPerRow)
        let rowH = uniformRowHeight(subviews)
        let totalH = rowH * CGFloat(counts.count) + spacing * CGFloat(max(0, counts.count - 1))
        // Width: respect the proposal when given; otherwise fall back to the
        // sum of the widest-row's intrinsic widths so the container is
        // measurable in unconstrained-proposal contexts (e.g. previews).
        if let proposed = proposal.width {
            return CGSize(width: proposed, height: totalH)
        }
        let widestRowCount = counts.max() ?? 0
        let intrinsicMax = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let fallbackW = intrinsicMax * CGFloat(widestRowCount) + spacing * CGFloat(max(0, widestRowCount - 1))
        return CGSize(width: fallbackW, height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let counts = balancedRowCounts(total: subviews.count, cap: capPerRow)
        let rowH = uniformRowHeight(subviews)
        var y = bounds.minY
        var idx = 0
        for n in counts {
            let nF = CGFloat(n)
            let availableWidth = bounds.width - spacing * max(0, nF - 1)
            let perItem = availableWidth / max(1, nF)
            var x = bounds.minX
            for _ in 0..<n {
                subviews[idx].place(at: CGPoint(x: x, y: y),
                                    anchor: .topLeading,
                                    proposal: ProposedViewSize(width: perItem, height: rowH))
                x += perItem + spacing
                idx += 1
            }
            y += rowH + spacing
        }
    }

    /// Distribute `total` items across `ceil(total / cap)` rows so that the
    /// row sizes differ by at most 1 and the smaller row(s) come first
    /// (so 5 → [2, 3] not [3, 2]).
    static func balancedRowCounts(total: Int, cap: Int = 4) -> [Int] {
        guard total > 0 else { return [] }
        let rowCount = max(1, (total + cap - 1) / cap)
        let base = total / rowCount
        let extras = total % rowCount
        var out: [Int] = []
        out.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            // First `(rowCount - extras)` rows get `base`; the rest get `base + 1`.
            // This puts smaller rows first (top) and larger rows last (bottom).
            out.append(r < (rowCount - extras) ? base : base + 1)
        }
        return out
    }

    private func balancedRowCounts(total: Int, cap: Int) -> [Int] {
        Self.balancedRowCounts(total: total, cap: cap)
    }

    private func uniformRowHeight(_ subviews: Subviews) -> CGFloat {
        var h: CGFloat = 0
        for s in subviews { h = max(h, s.sizeThatFits(.unspecified).height) }
        return h
    }
}
