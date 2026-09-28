import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    private var learnedMinimumTilingSize: CGSize = .zero
    private var minimumTilingWidthCandidate: MinimumTilingSizeCandidate?
    private var minimumTilingHeightCandidate: MinimumTilingSizeCandidate?
    private var minimumTilingProbeStreak = 0
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

private struct MinimumTilingSizeCandidate {
    let requested: CGFloat
    let actual: CGFloat
    var confirmations: Int
}

enum MinimumTilingSizeObservationResult: Equatable {
    case accepted
    case retry
    case learned
}

extension Window {
    /// Remember dimensions that an app consistently refuses through the
    /// Accessibility API. Immediate AX reads can briefly return the previous
    /// size, so one rejection is only a probe and must not poison future
    /// layouts with a bogus minimum.
    @MainActor
    @discardableResult
    func observeTilingSize(requested: CGSize, actual: CGSize) -> MinimumTilingSizeObservationResult {
        let widthResult = observeMinimumTilingDimension(
            requested: requested.width,
            actual: actual.width,
            learned: &learnedMinimumTilingSize.width,
            candidate: &minimumTilingWidthCandidate,
        )
        let heightResult = observeMinimumTilingDimension(
            requested: requested.height,
            actual: actual.height,
            learned: &learnedMinimumTilingSize.height,
            candidate: &minimumTilingHeightCandidate,
        )
        if widthResult == .learned || heightResult == .learned {
            minimumTilingProbeStreak = 0
            return .learned
        }
        guard widthResult == .retry || heightResult == .retry else {
            minimumTilingProbeStreak = 0
            return .accepted
        }
        // Each probe schedules a refresh. An app whose reported size never
        // settles must not keep AeroSpace refreshing forever.
        minimumTilingProbeStreak += 1
        return minimumTilingProbeStreak <= minimumTilingSizeMaxProbeStreak ? .retry : .accepted
    }

    /// The minimum size learned from the app, or zero for a dimension it has
    /// never refused. Tiled layout reserves this much space before placing
    /// the window (see `reserveMinimumTilingLengths`).
    @MainActor
    var minimumTilingSize: CGSize { learnedMinimumTilingSize }

    /// Forget the learned minimum so the next layouts measure it again. A
    /// learned minimum only grows, so an explicit re-measure is the way to
    /// recover space after an app's own minimum shrinks.
    @MainActor
    func forgetMinimumTilingSize() {
        learnedMinimumTilingSize = .zero
        minimumTilingWidthCandidate = nil
        minimumTilingHeightCandidate = nil
        minimumTilingProbeStreak = 0
    }

    /// Enlarge the frame to the minimum learned from the app and shift it back
    /// inside the workspace. Layout already reserves the minimum in the
    /// enclosing splits, so this only changes the frame when the minimums of
    /// neighboring windows cannot all fit, in which case overlap is
    /// unavoidable. It must not change weights or schedule refreshes: doing so
    /// from inside a layout pass made two constrained neighbors trade space
    /// back and forth forever.
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

private let minimumTilingSizeTolerance: CGFloat = 1
private let minimumTilingSizeConfirmationCount = 3
private let minimumTilingSizeMaxProbeStreak = 8

private func observeMinimumTilingDimension(
    requested: CGFloat,
    actual: CGFloat,
    learned: inout CGFloat,
    candidate: inout MinimumTilingSizeCandidate?,
) -> MinimumTilingSizeObservationResult {
    guard actual > requested + minimumTilingSizeTolerance else {
        candidate = nil
        return .accepted
    }
    guard learned < actual - minimumTilingSizeTolerance else {
        candidate = nil
        return .accepted
    }

    if var existing = candidate,
       abs(existing.requested - requested) <= minimumTilingSizeTolerance,
       abs(existing.actual - actual) <= minimumTilingSizeTolerance
    {
        existing.confirmations += 1
        candidate = existing
    } else {
        candidate = MinimumTilingSizeCandidate(requested: requested, actual: actual, confirmations: 1)
    }

    guard let candidate, candidate.confirmations >= minimumTilingSizeConfirmationCount else {
        return .retry
    }
    learned = max(learned, candidate.actual)
    return .learned
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
