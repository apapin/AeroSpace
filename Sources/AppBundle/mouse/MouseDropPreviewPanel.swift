import AppKit

/// Click-through visual feedback for the pending mouse drop. AppKit is enough
/// here: unlike yabai's private SkyLight window, this panel trades exact target
/// sub-level ordering for a stable public API.
@MainActor
final class MouseDropPreviewPanel: NSPanel {
    static let shared = MouseDropPreviewPanel()

    private let previewView = NSView(frame: .zero)

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        previewView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        previewView.layer?.borderWidth = 2
        previewView.layer?.cornerRadius = 9
        contentView = previewView
    }

    func show(_ rect: Rect) {
        let appKitRect = NSRect(
            x: rect.topLeftX,
            y: mainMonitor.height - rect.maxY,
            width: rect.width,
            height: rect.height,
        )
        setFrame(appKitRect, display: true)
        previewView.frame = NSRect(origin: .zero, size: appKitRect.size)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
