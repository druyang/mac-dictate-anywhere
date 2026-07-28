import SwiftUI

/// Atom: flows subviews left to right and wraps onto a new row when the
/// proposed width runs out — the text-like line breaking SwiftUI's stacks
/// can't do. Used by the Read Aloud reader, where every word is its own
/// tappable view but the block still has to read like a paragraph.
struct DSWrapLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 3

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // A scroll view probes with an unspecified width; answering with an
        // infinite width there leaves it with nothing it can draw.
        let availableWidth: CGFloat
        if let width = proposal.width, width > 0, width.isFinite {
            availableWidth = width
        } else {
            availableWidth = .infinity
        }

        let rows = rows(fitting: availableWidth, sizes: sizes)
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        return CGSize(
            width: availableWidth.isFinite
                ? availableWidth
                : (rows.map(\.width).max() ?? 0),
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY

        for row in rows(fitting: bounds.width, sizes: sizes) {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(fitting maxWidth: CGFloat, sizes: [CGSize]) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for (index, size) in sizes.enumerated() {
            let advance = row.indices.isEmpty ? size.width : size.width + horizontalSpacing
            if !row.indices.isEmpty, row.width + advance > maxWidth {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
                continue
            }
            row.indices.append(index)
            row.width += advance
            row.height = max(row.height, size.height)
        }

        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
