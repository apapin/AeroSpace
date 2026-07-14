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
        if config.bspAutoBalance == .off, let lastAppliedLayoutVirtualRect {
            return lastAppliedLayoutVirtualRect
        }
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
            if config.bspAutoBalance == .off, let cached = child.lastAppliedLayoutVirtualRect {
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

private struct BspRebalanceGroup {
    let workspace: Workspace
    var anchors: [TreeNode]
}

/// Rebalance only the BSP paths affected by a structural edit, or the entire
/// workspace when requested by config. Grouping anchors first lets a drag
/// between workspaces update both trees in one transaction.
@MainActor
func rebalanceBspAfterTopologyChange(around anchors: [TreeNode]) {
    guard config.enableBspLayout, config.bspAutoBalance != .off else { return }

    var groups: [BspRebalanceGroup] = []
    for anchor in anchors {
        guard let workspace = anchor.nodeWorkspace else { continue }
        if let index = groups.firstIndex(where: { $0.workspace === workspace }) {
            groups[index].anchors.append(anchor)
        } else {
            groups.append(BspRebalanceGroup(workspace: workspace, anchors: [anchor]))
        }
    }
    for group in groups {
        rebalanceBspWorkspace(group.workspace, around: group.anchors)
    }
}

@MainActor
private func rebalanceBspWorkspace(_ workspace: Workspace, around anchors: [TreeNode]) {
    let root = workspace.rootTilingContainer
    var selectedContainers: Set<ObjectIdentifier> = []

    switch config.bspAutoBalance {
        case .off:
            return
        case .ancestors:
            for anchor in anchors where anchor.nodeWorkspace === workspace {
                for node in anchor.parentsWithSelf {
                    if let container = node as? TilingContainer, container.layout == .tiles {
                        selectedContainers.insert(ObjectIdentifier(container))
                    }
                }
            }
        case .workspace:
            func selectRecursively(_ node: TreeNode) {
                guard let container = node as? TilingContainer, container.layout == .tiles else { return }
                selectedContainers.insert(ObjectIdentifier(container))
                for child in container.children {
                    selectRecursively(child)
                }
            }
            selectRecursively(root)
    }
    guard !selectedContainers.isEmpty else { return }

    var slotCounts: [ObjectIdentifier: Int] = [:]
    @discardableResult
    func countSlots(_ node: TreeNode) -> Int {
        let count: Int = if let container = node as? TilingContainer {
            switch container.layout {
                case .tiles:
                    container.children.reduce(0) { $0 + countSlots($1) }
                case .accordion, .stack:
                    container.isEffectivelyEmpty ? 0 : 1
            }
        } else {
            node is Window ? 1 : 0
        }
        slotCounts[ObjectIdentifier(node)] = count
        return count
    }
    countSlots(root)

    func applyWeights(_ container: TilingContainer, in rect: Rect) {
        guard container.layout == .tiles, !container.children.isEmpty else { return }

        let dimension = rect.getDimension(container.orientation)
        let shouldBalance = selectedContainers.contains(ObjectIdentifier(container))
        let childCounts = container.children.map { slotCounts[ObjectIdentifier($0)] ?? 0 }
        let totalCount = childCounts.reduce(0, +)
        let lengths: [CGFloat]

        if shouldBalance, totalCount > 0 {
            var consumed: CGFloat = 0
            lengths = container.children.indices.map { index in
                let length = index == container.children.indices.last
                    ? dimension - consumed
                    : dimension * CGFloat(childCounts[index]) / CGFloat(totalCount)
                consumed += length
                return length
            }
            for (child, length) in zip(container.children, lengths) {
                child.setWeight(container.orientation, length)
            }
        } else {
            let totalWeight = container.children.reduce(CGFloat(0)) {
                $0 + $1.getWeight(container.orientation)
            }
            let delta = (dimension - totalWeight) / CGFloat(container.children.count)
            lengths = container.children.map { $0.getWeight(container.orientation) + delta }
        }

        var offset: CGFloat = 0
        for (child, length) in zip(container.children, lengths) {
            let childRect = container.orientation == .h
                ? Rect(
                    topLeftX: rect.topLeftX + offset,
                    topLeftY: rect.topLeftY,
                    width: length,
                    height: rect.height,
                )
                : Rect(
                    topLeftX: rect.topLeftX,
                    topLeftY: rect.topLeftY + offset,
                    width: rect.width,
                    height: length,
                )
            if let child = child as? TilingContainer {
                applyWeights(child, in: childRect)
            }
            offset += length
        }
    }

    applyWeights(root, in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)
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
    rebalanceBspAfterTopologyChange(around: [window])
}
