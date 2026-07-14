import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    private var learnedMinimumTilingSize: CGSize = .zero
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

extension Window {
    /// Remember dimensions that an app demonstrably refused through the
    /// Accessibility API. macOS doesn't expose a reliable minimum-window-size
    /// attribute, so the first rejected resize is our only dependable signal.
    @MainActor
    @discardableResult
    func learnMinimumTilingSize(requested: CGSize, actual: CGSize) -> Bool {
        let tolerance: CGFloat = 1
        let old = learnedMinimumTilingSize
        if actual.width > requested.width + tolerance {
            learnedMinimumTilingSize.width = max(old.width, actual.width)
        }
        if actual.height > requested.height + tolerance {
            learnedMinimumTilingSize.height = max(old.height, actual.height)
        }
        return old != learnedMinimumTilingSize
    }

    /// Expand an undersized BSP leaf to the minimum learned from the app and
    /// shift it back inside the workspace. Overlap is preferable to repeatedly
    /// asking for an impossible frame: the latter can make some apps jump to a
    /// monitor corner and emit a self-sustaining move/resize notification loop.
    @MainActor
    func resolveTilingFrame(_ requested: Rect, within bounds: Rect) -> Rect {
        let width = max(requested.width, learnedMinimumTilingSize.width)
        let height = max(requested.height, learnedMinimumTilingSize.height)
        let maxX = max(bounds.minX, bounds.maxX - width)
        let maxY = max(bounds.minY, bounds.maxY - height)
        return Rect(
            topLeftX: requested.topLeftX.coerce(in: bounds.minX ... maxX),
            topLeftY: requested.topLeftY.coerce(in: bounds.minY ... maxY),
            width: width,
            height: height,
        )
    }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
