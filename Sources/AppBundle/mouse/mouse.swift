import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
@MainActor private(set) var currentMouseManipulationKind: MouseManipulationKind? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

enum MouseManipulationKind: Equatable {
    case move
    case resize
}

@MainActor
func beginMoveManipulation(windowId: UInt32) -> Bool {
    guard currentMouseManipulationKind != .resize else { return false }
    currentMouseManipulationKind = .move
    currentlyManipulatedWithMouseWindowId = windowId
    return true
}

@MainActor
func beginResizeManipulation(windowId: UInt32) {
    currentMouseManipulationKind = .resize
    currentlyManipulatedWithMouseWindowId = windowId
    resetMoveWithMouseState()
}

@MainActor
func resetMouseManipulationTracking() {
    currentMouseManipulationKind = nil
    currentlyManipulatedWithMouseWindowId = nil
}

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
