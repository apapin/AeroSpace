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

enum MouseDropOperation: Equatable {
    case swap(targetWindowId: UInt32)
    case stack(targetWindowId: UInt32)
    case warp(targetWindowId: UInt32, direction: CardinalDirection)
    case moveToWorkspace(String)
}

struct MouseDropPlan {
    let sourceWindowId: UInt32
    let operation: MouseDropOperation
    let previewRect: Rect?
}

private struct MouseHitTarget {
    let window: Window
    let frame: Rect
}

@MainActor
private var pendingMouseDropPlan: MouseDropPlan? = nil

@MainActor
private var mouseDragSourceWindowId: UInt32? = nil

@MainActor
func resetMoveWithMouseState() {
    pendingMouseDropPlan = nil
    mouseDragSourceWindowId = nil
    if !isUnitTest {
        MouseDropPreviewPanel.shared.hide()
    }
}

@MainActor
func commitPendingMouseDropIfPossible() {
    defer { resetMoveWithMouseState() }
    guard let sourceWindowId = mouseDragSourceWindowId,
          let window = Window.get(byId: sourceWindowId) else { return }

    // Recompute from the release position. AX move notifications can lag
    // behind the pointer, and a transactional drop must use the final target.
    let finalPlan = currentMouseDropPlan(for: window)
    guard let finalPlan else { return }
    commitMouseDropPlan(finalPlan)
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    guard beginMoveManipulation(windowId: window.windowId) else { return }
    mouseDragSourceWindowId = window.windowId
    pendingMouseDropPlan = currentMouseDropPlan(for: window)
    if !isUnitTest {
        if let previewRect = pendingMouseDropPlan?.previewRect {
            MouseDropPreviewPanel.shared.show(previewRect)
        } else {
            MouseDropPreviewPanel.shared.hide()
        }
    }
}

@MainActor
private func currentMouseDropPlan(for window: Window) -> MouseDropPlan? {
    let location = mouseLocation
    let targetWorkspace = location.monitorApproximation.activeWorkspace
    let target = topmostTilingWindow(
        at: location,
        in: targetWorkspace,
        excluding: window.windowId,
    )
    return makeMouseDropPlan(
        source: window,
        targetWorkspace: targetWorkspace,
        target: target?.window,
        targetRect: target?.frame,
        location: location,
    )
}

@MainActor
func makeMouseDropPlan(
    source: Window,
    targetWorkspace: Workspace,
    target: Window?,
    targetRect: Rect?,
    location: CGPoint,
) -> MouseDropPlan? {
    if let target, target !== source, source.bspSlot !== target.bspSlot, let targetRect {
        let zone = location.dropZone(in: targetRect)
        if zone == .center && !source.isOnlyWindowInBspSlot {
            return nil
        }
        let operation: MouseDropOperation = switch zone {
            case .center:
                switch config.mouseDropAction {
                    case .swap: .swap(targetWindowId: target.windowId)
                    case .stack: .stack(targetWindowId: target.windowId)
                }
            case .edge(let direction):
                .warp(targetWindowId: target.windowId, direction: direction)
        }
        return MouseDropPlan(
            sourceWindowId: source.windowId,
            operation: operation,
            previewRect: targetRect.previewRect(for: zone),
        )
    }

    guard targetWorkspace != source.nodeWorkspace else { return nil }
    return MouseDropPlan(
        sourceWindowId: source.windowId,
        operation: .moveToWorkspace(targetWorkspace.name),
        previewRect: nil,
    )
}

@MainActor
func commitMouseDropPlan(_ plan: MouseDropPlan) {
    guard let source = Window.get(byId: plan.sourceWindowId) else { return }
    switch plan.operation {
        case .swap(let targetWindowId):
            guard let target = Window.get(byId: targetWindowId) else { return }
            swapBspSlots(mruDominant: source, target)
        case .stack(let targetWindowId):
            guard let target = Window.get(byId: targetWindowId) else { return }
            stackWindow(source, onto: target)
        case .warp(let targetWindowId, let direction):
            guard let target = Window.get(byId: targetWindowId) else { return }
            reparentWindowForMouseDrop(source, relativeTo: target, direction: direction)
        case .moveToWorkspace(let workspaceName):
            moveWindowForMouseDrop(source, to: Workspace.get(byName: workspaceName))
    }
}

@MainActor
private func moveWindowForMouseDrop(_ window: Window, to workspace: Workspace) {
    guard workspace != window.nodeWorkspace else { return }
    let target = workspace.mostRecentWindowRecursive
    if let target,
       let targetParent = target.parent as? TilingContainer,
       targetParent.layout == .tiles,
       config.enableBspLayout
    {
        window.bind(
            to: targetParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: target.ownIndex.orDie() + 1,
        )
        insertWindowUsingBsp(window, splitting: target)
    } else {
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
    }
}

@MainActor
func reparentWindowForMouseDrop(
    _ window: Window,
    relativeTo target: Window,
    direction: CardinalDirection,
) {
    let targetSlot = target.bspSlot
    if window === target || window.bspSlot === targetSlot { return }
    guard let targetParent = targetSlot.parent as? TilingContainer else { return }

    let placeAfterTarget = direction.isPositive
    if window.parent === targetParent,
       targetParent.layout == .tiles,
       targetParent.orientation == direction.orientation,
       targetParent.children.count == 2,
       let windowIndex = window.ownIndex,
       let targetIndex = targetSlot.ownIndex
    {
        if placeAfterTarget ? targetIndex + 1 == windowIndex : windowIndex + 1 == targetIndex {
            return
        }

        let windowBinding = window.unbindFromParent()
        targetSlot.markAsMostRecentChild()
        window.bind(
            to: targetParent,
            adaptiveWeight: windowBinding.adaptiveWeight,
            index: placeAfterTarget ? 1 : 0,
        )
        return
    }

    window.unbindFromParent()
    let targetBinding = targetSlot.unbindFromParent()
    let wrapper = TilingContainer(
        parent: targetBinding.parent,
        adaptiveWeight: targetBinding.adaptiveWeight,
        direction.orientation,
        .tiles,
        index: targetBinding.index,
    )
    wrapper.preserveMouseDropOrientation()
    if placeAfterTarget {
        targetSlot.bind(to: wrapper, adaptiveWeight: 1, index: 0)
        window.bind(to: wrapper, adaptiveWeight: 1, index: 1)
    } else {
        window.bind(to: wrapper, adaptiveWeight: 1, index: 0)
        targetSlot.bind(to: wrapper, adaptiveWeight: 1, index: 1)
    }
    window.markAsMostRecentChild()
}

@MainActor
private func topmostTilingWindow(
    at point: CGPoint,
    in workspace: Workspace,
    excluding excludedWindowId: UInt32,
) -> MouseHitTarget? {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    if let windowList = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] {
        for rawInfo in windowList {
            let info = rawInfo as NSDictionary
            guard let number = info[kCGWindowNumber] as? NSNumber else { continue }
            let windowId = number.uint32Value
            guard windowId != excludedWindowId,
                  let window = Window.get(byId: windowId),
                  window.nodeWorkspace == workspace else { continue }
            guard case .tilingContainer = window.windowParentCases else { continue }
            guard let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            let frame = Rect(
                topLeftX: bounds.origin.x,
                topLeftY: bounds.origin.y,
                width: bounds.width,
                height: bounds.height,
            )
            if frame.contains(point) {
                return MouseHitTarget(window: window, frame: frame)
            }
        }
    }

    guard let window = point
        .findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf({ $0.windowId != excludedWindowId }),
        let frame = window.lastAppliedLayoutPhysicalRect else { return nil }
    return MouseHitTarget(window: window, frame: frame)
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

extension Rect {
    func previewRect(for zone: MouseDropZone) -> Rect {
        switch zone {
            case .center:
                self
            case .edge(.left):
                Rect(topLeftX: topLeftX, topLeftY: topLeftY, width: width / 2, height: height)
            case .edge(.right):
                Rect(topLeftX: topLeftX + width / 2, topLeftY: topLeftY, width: width / 2, height: height)
            case .edge(.up):
                Rect(topLeftX: topLeftX, topLeftY: topLeftY, width: width, height: height / 2)
            case .edge(.down):
                Rect(topLeftX: topLeftX, topLeftY: topLeftY + height / 2, width: width, height: height / 2)
        }
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
            case .stack:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
