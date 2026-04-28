import SwiftUI

/// Flexbox-style flow layout: subviews fill rows left-to-right, wrap when out of space,
/// and each row's children expand equally to fill the row width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = makeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(0.0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let totalWidth = rows.map(\.idealWidth).max() ?? 0
        return CGSize(width: min(maxWidth, totalWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let n = CGFloat(row.indices.count)
            let availableWidth = bounds.width - spacing * max(0, n - 1)
            let perItem = availableWidth / max(1, n)
            var x = bounds.minX
            for idx in row.indices {
                let sv = subviews[idx]
                sv.place(at: CGPoint(x: x, y: y),
                         anchor: .topLeading,
                         proposal: ProposedViewSize(width: perItem, height: row.height))
                x += perItem + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var idealWidth: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let w = size.width
            let h = size.height
            let lastIdx = rows.count - 1
            let lastRow = rows[lastIdx]
            let proposed = lastRow.idealWidth + (lastRow.indices.isEmpty ? 0 : spacing) + w
            if proposed <= maxWidth || lastRow.indices.isEmpty {
                rows[lastIdx].indices.append(i)
                rows[lastIdx].idealWidth = proposed
                rows[lastIdx].height = max(rows[lastIdx].height, h)
            } else {
                var newRow = Row()
                newRow.indices.append(i)
                newRow.idealWidth = w
                newRow.height = h
                rows.append(newRow)
            }
        }
        return rows
    }
}
