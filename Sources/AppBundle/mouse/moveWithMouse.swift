import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

enum MouseDropZone: Equatable {
    case center
    case edge(CardinalDirection)
}

private struct MouseDragAction: Equatable {
    let draggedWindowId: UInt32
    let targetWindowId: UInt32
    let dropZone: MouseDropZone
}

@MainActor
private var lastMouseDragAction: MouseDragAction? = nil

@MainActor
func resetMoveWithMouseState() {
    lastMouseDragAction = nil
}

@MainActor
private func shouldPerformMouseDragAction(_ action: MouseDragAction) -> Bool {
    if lastMouseDragAction == action { return false }
    lastMouseDragAction = action
    return true
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let target = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }

    guard config.mouseDragDropAction == .reparent else {
        resetMoveWithMouseState()
        moveTilingWindowUsingSwap(window, targetWorkspace, target, mouseLocation)
        return
    }

    guard let target, let targetRect = target.lastAppliedLayoutPhysicalRect else {
        resetMoveWithMouseState()
        if targetWorkspace != window.nodeWorkspace {
            window.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        }
        return
    }

    let dropZone = mouseLocation.dropZone(in: targetRect)
    let action = MouseDragAction(
        draggedWindowId: window.windowId,
        targetWindowId: target.windowId,
        dropZone: dropZone,
    )
    guard shouldPerformMouseDragAction(action) else { return }

    switch dropZone {
        case .center where targetWorkspace == window.nodeWorkspace:
            swapWindows(mruDominant: window, target)
        case .center:
            moveTilingWindowUsingSwap(window, targetWorkspace, target, mouseLocation)
        case .edge(let direction):
            reparentWindowForMouseDrop(window, relativeTo: target, direction: direction)
    }
}

@MainActor
private func moveTilingWindowUsingSwap(
    _ window: Window,
    _ targetWorkspace: Workspace,
    _ swapTarget: Window?,
    _ mouseLocation: CGPoint,
) {
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect {
            mouseLocation.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? swapTarget.ownIndex.orDie() + 1
                : swapTarget.ownIndex.orDie()
        } else {
            0
        }
        window.bind(
            to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let swapTarget {
        swapWindows(mruDominant: window, swapTarget)
    }
}

@MainActor
func reparentWindowForMouseDrop(
    _ window: Window,
    relativeTo target: Window,
    direction: CardinalDirection,
) {
    if window == target { return }
    guard let targetParent = target.parent as? TilingContainer else { return }

    let placeAfterTarget = direction.isPositive
    if window.parent === targetParent,
       targetParent.layout == .tiles,
       targetParent.orientation == direction.orientation,
       targetParent.children.count == 2,
       let windowIndex = window.ownIndex,
       let targetIndex = target.ownIndex
    {
        if placeAfterTarget ? targetIndex + 1 == windowIndex : windowIndex + 1 == targetIndex {
            return
        }

        let windowBinding = window.unbindFromParent()
        target.markAsMostRecentChild()
        window.bind(
            to: targetParent,
            adaptiveWeight: windowBinding.adaptiveWeight,
            index: placeAfterTarget ? 1 : 0,
        )
        return
    }

    window.unbindFromParent()
    let targetBinding = target.unbindFromParent()
    let wrapper = TilingContainer(
        parent: targetBinding.parent,
        adaptiveWeight: targetBinding.adaptiveWeight,
        direction.orientation,
        .tiles,
        index: targetBinding.index,
    )
    wrapper.preserveMouseDropOrientation()
    if placeAfterTarget {
        target.bind(to: wrapper, adaptiveWeight: 1, index: 0)
        window.bind(to: wrapper, adaptiveWeight: 1, index: 1)
    } else {
        window.bind(to: wrapper, adaptiveWeight: 1, index: 0)
        target.bind(to: wrapper, adaptiveWeight: 1, index: 1)
    }
    window.markAsMostRecentChild()
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension CGPoint {
    func dropZone(in rect: Rect, edgeRatio: CGFloat = 0.25) -> MouseDropZone {
        guard rect.contains(self), rect.width > 0, rect.height > 0 else { return .center }

        let distances: [(ratio: CGFloat, direction: CardinalDirection)] = [
            ((x - rect.minX) / rect.width, .left),
            ((rect.maxX - x) / rect.width, .right),
            ((y - rect.minY) / rect.height, .up),
            ((rect.maxY - y) / rect.height, .down),
        ]
        guard let closest = distances.min(by: { $0.ratio < $1.ratio }), closest.ratio <= edgeRatio else {
            return .center
        }
        return .edge(closest.direction)
    }
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
