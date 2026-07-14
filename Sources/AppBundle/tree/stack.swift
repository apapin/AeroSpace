import Common

extension Window {
    /// The BSP leaf represented by this window. A stack container is a single
    /// leaf even though it owns several windows.
    var bspSlot: TreeNode {
        stackContainer ?? self
    }

    var stackContainer: TilingContainer? {
        parents.lazy
            .compactMap { $0 as? TilingContainer }
            .first(where: { $0.layout == .stack })
    }

    var isOnlyWindowInBspSlot: Bool {
        stackContainer?.allLeafWindowsRecursive.count ?? 1 == 1
    }
}

/// Put `source` into the same BSP leaf as `target`. The target leaf keeps its
/// outer weight and geometry; only the list of full-size windows in that leaf
/// changes.
@MainActor
func stackWindow(_ source: Window, onto target: Window) {
    guard source !== target, source.bspSlot !== target.bspSlot else { return }

    source.unbindFromParent()
    if let targetStack = target.stackContainer {
        source.bind(to: targetStack, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    } else {
        let targetBinding = target.unbindFromParent()
        let inheritedOrientation = (targetBinding.parent as? TilingContainer)?.orientation ?? .h
        let stack = TilingContainer(
            parent: targetBinding.parent,
            adaptiveWeight: targetBinding.adaptiveWeight,
            inheritedOrientation,
            .stack,
            index: targetBinding.index,
        )
        target.bind(to: stack, adaptiveWeight: 1, index: 0)
        source.bind(to: stack, adaptiveWeight: 1, index: 1)
    }
    source.markAsMostRecentChild()
}

/// Swap BSP leaves rather than individual windows. In particular, dropping a
/// singleton onto a stack exchanges it with the whole stack, matching yabai's
/// node-level swap semantics.
@MainActor
func swapBspSlots(mruDominant source: Window, _ target: Window) {
    let sourceSlot = source.bspSlot
    let targetSlot = target.bspSlot
    guard sourceSlot !== targetSlot else { return }

    let targetBinding = targetSlot.unbindFromParent()
    let sourceBinding = sourceSlot.unbindFromParent()
    targetSlot.bind(
        to: sourceBinding.parent,
        adaptiveWeight: sourceBinding.adaptiveWeight,
        index: sourceBinding.index,
    )
    sourceSlot.bind(
        to: targetBinding.parent,
        adaptiveWeight: targetBinding.adaptiveWeight,
        index: targetBinding.index,
    )
    source.markAsMostRecentChild()
}

extension Window {
    @MainActor
    func resolveStackFocusTarget(_ target: StackFocusTarget) -> Window? {
        guard let stack = stackContainer else { return nil }
        let windows = stack.allLeafWindowsRecursive
        guard windows.count > 1, let ownIndex = windows.firstIndex(of: self) else { return nil }

        return switch target {
            case .stackPrev: windows.getOrNil(atIndex: ownIndex - 1)
            case .stackNext: windows.getOrNil(atIndex: ownIndex + 1)
            case .stackFirst: windows.first
            case .stackLast: windows.last
            case .stackRecent:
                stack.mruChildren.lazy
                    .compactMap(\.mostRecentWindowRecursive)
                    .first(where: { $0 !== self })
        }
    }
}
