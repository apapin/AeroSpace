import AppKit
import Common

extension TilingContainer {
    /// Give each child of a tiles container at least the length its windows'
    /// learned minimum sizes need, before any child is laid out.
    ///
    /// `available` must equal the sum of the children's weights along the
    /// container orientation (layoutTiles normalizes them first). The adjusted
    /// weights are a fixed point of this function, so the next layout pass
    /// leaves them unchanged and no follow-up refresh is needed.
    @MainActor
    func reserveMinimumTilingLengths(available: CGFloat, innerGap: CGFloat, accordionPadding: CGFloat) {
        guard layout == .tiles, children.count > 1 else { return }
        let lastIndex = children.count - 1
        let minimums: [CGFloat] = children.enumerated().map { index, child in
            let minimum = child.minimumTilingLength(orientation, innerGap: innerGap, accordionPadding: accordionPadding)
            guard minimum > 0 else { return 0 }
            // A child's physical size excludes its share of the inner gaps (see layoutTiles).
            let gap = innerGap - (index == 0 ? innerGap / 2 : 0) - (index == lastIndex ? innerGap / 2 : 0)
            return minimum + gap
        }
        guard minimums.contains(where: { $0 > 0 }) else { return }
        let lengths = children.map { $0.getWeight(orientation) }
        let adjusted = allocateTilingLengths(lengths, minimums: minimums, total: available)
        for (child, length) in zip(children, adjusted) {
            child.setWeight(orientation, length)
        }
    }
}

extension TreeNode {
    /// The length along `orientation` this subtree needs so that none of its
    /// windows is smaller than the minimum size its app enforces. Zero when no
    /// window in the subtree has a learned minimum in that dimension.
    @MainActor
    func minimumTilingLength(_ orientation: Orientation, innerGap: CGFloat, accordionPadding: CGFloat) -> CGFloat {
        switch nodeCases {
            case .window(let window):
                return orientation == .h ? window.minimumTilingSize.width : window.minimumTilingSize.height
            case .tilingContainer(let container):
                let childMinimums = container.children.map {
                    $0.minimumTilingLength(orientation, innerGap: innerGap, accordionPadding: accordionPadding)
                }
                guard let largest = childMinimums.max(), largest > 0 else { return 0 }
                switch container.layout {
                    case .tiles where container.orientation == orientation:
                        return childMinimums.reduce(0, +) + innerGap * CGFloat(container.children.count - 1)
                    case .accordion where container.orientation == orientation:
                        return largest + (container.children.count > 1 ? 2 * accordionPadding : 0)
                    case .tiles, .accordion, .stack:
                        return largest
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return 0
        }
    }
}

private let tilingLengthTolerance: CGFloat = 0.5

/// Adjust `lengths`, which sum to `total`, so that each entry is at least the
/// matching entry of `minimums`.
///
/// When the minimums fit, each deficit is funded by the other entries in
/// proportion to their surplus above their own minimum. When they cannot all
/// fit, `total` is shared in proportion to each entry's claim: its minimum, or
/// an equal share for an entry without one. In both cases the result is a
/// fixed point: passing it back in returns it unchanged.
func allocateTilingLengths(_ lengths: [CGFloat], minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
    guard lengths.count == minimums.count, !lengths.isEmpty else { return lengths }

    if minimums.reduce(0, +) <= total + tilingLengthTolerance {
        let totalDeficit = zip(lengths, minimums).reduce(0) { $0 + max(0, $1.1 - $1.0) }
        guard totalDeficit > tilingLengthTolerance else { return lengths }
        let totalSurplus = zip(lengths, minimums).reduce(0) { $0 + max(0, $1.0 - $1.1) }
        guard totalSurplus > 0 else { return lengths }
        let ratio = min(1, totalDeficit / totalSurplus)
        return zip(lengths, minimums).map { length, minimum in
            length < minimum ? minimum : length - (length - minimum) * ratio
        }
    }

    let equalShare = total / CGFloat(lengths.count)
    let claims = minimums.map { $0 > 0 ? $0 : equalShare }
    let totalClaim = claims.reduce(0, +)
    return claims.map { total * $0 / totalClaim }
}
