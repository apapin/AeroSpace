import AppKit
import Common

/// Choose the split that gives the two children the longest available edge,
/// matching yabai's `split_type=auto` policy.
func longestSideBspOrientation(_ rect: Rect) -> Orientation {
    rect.width >= rect.height ? .h : .v
}

extension TreeNode {
    /// Return the node's current logical region even before the first layout
    /// pass. Startup discovers several windows in one refresh, so relying only
    /// on `lastAppliedLayoutVirtualRect` would make every early split use the
    /// full monitor aspect ratio.
    @MainActor
    func estimatedTilingRect() -> Rect? {
        if let lastAppliedLayoutVirtualRect { return lastAppliedLayoutVirtualRect }
        guard let workspace = nodeWorkspace else { return nil }

        let root = workspace.rootTilingContainer
        var rect = root.lastAppliedLayoutVirtualRect
            ?? workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        if self === root { return rect }

        var path: [TreeNode] = []
        var cursor: TreeNode? = self
        while let node = cursor, node !== root {
            path.append(node)
            cursor = node.parent
        }
        guard cursor === root else { return nil }

        var parent = root
        for child in path.reversed() {
            if let cached = child.lastAppliedLayoutVirtualRect {
                rect = cached
            } else if parent.layout == .tiles,
                      let childIndex = parent.children.firstIndex(of: child),
                      !parent.children.isEmpty
            {
                let dimension = rect.getDimension(parent.orientation)
                let totalWeight = CGFloat(parent.children.sumOfDouble { $0.getWeight(parent.orientation) })
                let delta = (dimension - totalWeight) / CGFloat(parent.children.count)
                let lengths = parent.children.map { $0.getWeight(parent.orientation) + delta }
                let offset = lengths.prefix(childIndex).reduce(0, +)
                let length = lengths[childIndex]
                if parent.orientation == .h {
                    rect = Rect(
                        topLeftX: rect.topLeftX + offset,
                        topLeftY: rect.topLeftY,
                        width: length,
                        height: rect.height,
                    )
                } else {
                    rect = Rect(
                        topLeftX: rect.topLeftX,
                        topLeftY: rect.topLeftY + offset,
                        width: rect.width,
                        height: length,
                    )
                }
            }

            guard let nextParent = child as? TilingContainer else { break }
            parent = nextParent
        }
        return rect
    }
}

/// Insert `window` by splitting `target` immediately. The general AeroSpace
/// tree representation stays intact, but BSP mode never needs a refresh-time
/// fold for ordinary new-window insertion.
@MainActor
func insertWindowUsingBsp(_ window: Window, splitting target: Window) {
    guard window !== target else { return }
    if window.isBound {
        window.unbindFromParent()
    }
    guard let targetParent = target.parent as? TilingContainer,
          targetParent.layout == .tiles else { return }

    let orientation = longestSideBspOrientation(
        target.estimatedTilingRect()
            ?? targetParent.estimatedTilingRect()
            ?? target.nodeWorkspace?.workspaceMonitor.visibleRectPaddedByOuterGaps
            ?? Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1),
    )

    if targetParent.children.count == 1 {
        targetParent.setBspOrientation(orientation)
        target.setWeight(orientation, 1)
        window.bind(to: targetParent, adaptiveWeight: 1, index: 1)
    } else {
        let targetBinding = target.unbindFromParent()
        let wrapper = TilingContainer(
            parent: targetBinding.parent,
            adaptiveWeight: targetBinding.adaptiveWeight,
            orientation,
            .tiles,
            index: targetBinding.index,
        )
        target.bind(to: wrapper, adaptiveWeight: 1, index: 0)
        window.bind(to: wrapper, adaptiveWeight: 1, index: 1)
    }
    window.markAsMostRecentChild()
}
