extension Workspace {
    @MainActor func normalizeContainers() {
        rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers && !config.enableBspLayout {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
        if config.enableBspLayout {
            rootTilingContainer.repairBspShape()
        }
    }
}

extension TilingContainer {
    /// Repair an n-ary node created by a generic tree command. Ordinary window
    /// insertion and mouse warps maintain the binary invariant directly; this
    /// pass is deliberately a safety net rather than the BSP algorithm.
    ///
    @MainActor func repairBspShape() {
        while layout == .tiles && children.count > 2 {
            // Top-2 MRU children, falling back to children[0]/children[1] if
            // the MRU stack is incomplete (defensive; in practice every bind
            // calls markAsMostRecentChild so the stack mirrors children).
            let mru = Array(mruChildren)
            guard let mostRecent = mru.first ?? children.first,
                  let secondMostRecent = mru.dropFirst().first ?? children.dropFirst().first,
                  mostRecent !== secondMostRecent else { break }
            // 'mostRecent !== secondMostRecent' guards against an MRU stack so
            // degenerate that the same child appears twice (would only happen
            // if markAsMostRecentChild had a bug and double-pushed). Bailing
            // with 'break' leaves the tree as it was rather than crashing the
            // whole normaliser pass; a partially-folded tree is still safe to
            // render and the next normalize call will retry.
            guard let mruIdx = mostRecent.ownIndex,
                  let secondIdx = secondMostRecent.ownIndex else { break }

            let pivotIdx = min(mruIdx, secondIdx)
            let firstChild = mruIdx < secondIdx ? mostRecent : secondMostRecent
            let secondChild = mruIdx < secondIdx ? secondMostRecent : mostRecent
            let wrapperWeight = secondMostRecent.getWeight(orientation)
            let wrapperOrientation = longestSideBspOrientation(
                secondMostRecent.estimatedTilingRect()
                    ?? estimatedTilingRect()
                    ?? Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1),
            )
            firstChild.unbindFromParent()
            secondChild.unbindFromParent()
            let wrapper = TilingContainer(
                parent: self,
                adaptiveWeight: wrapperWeight,
                wrapperOrientation,
                .tiles,
                index: pivotIdx,
            )
            firstChild.bind(to: wrapper, adaptiveWeight: 1, index: 0)
            secondChild.bind(to: wrapper, adaptiveWeight: 1, index: 1)
        }
        for child in children {
            (child as? TilingContainer)?.repairBspShape()
        }
    }

    @MainActor fileprivate func unbindEmptyAndAutoFlatten() {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
