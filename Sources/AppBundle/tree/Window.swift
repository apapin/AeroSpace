import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    private var learnedMinimumTilingSize: CGSize = .zero
    private var minimumTilingWidthCandidate: MinimumTilingSizeCandidate?
    private var minimumTilingHeightCandidate: MinimumTilingSizeCandidate?
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
            return .learned
        }
        return widthResult == .retry || heightResult == .retry ? .retry : .accepted
    }

    /// Expand an undersized BSP leaf to the minimum learned from the app and
    /// shift it back inside the workspace. First grow the closest matching
    /// ancestor slot by taking space from its siblings so a real minimum does
    /// not turn into a persistent overlap.
    @MainActor
    func resolveTilingFrame(_ requested: Rect, within bounds: Rect) -> Rect {
        var didAdjustWeights = false
        if learnedMinimumTilingSize.width > requested.width + minimumTilingSizeTolerance {
            didAdjustWeights = growTilingSlot(
                by: learnedMinimumTilingSize.width - requested.width,
                orientation: .h,
            ) || didAdjustWeights
        }
        if learnedMinimumTilingSize.height > requested.height + minimumTilingSizeTolerance {
            didAdjustWeights = growTilingSlot(
                by: learnedMinimumTilingSize.height - requested.height,
                orientation: .v,
            ) || didAdjustWeights
        }
        if didAdjustWeights, !isUnitTest {
            scheduleCancellableCompleteRefreshSession(.ax("minimumTilingSizeReconciled"))
        }

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

    @MainActor
    private func growTilingSlot(by requestedDelta: CGFloat, orientation: Orientation) -> Bool {
        guard requestedDelta > minimumTilingSizeTolerance else { return false }
        guard let slot = parentsWithSelf.first(where: {
            guard let parent = $0.parent as? TilingContainer else { return false }
            return parent.layout == .tiles && parent.orientation == orientation && parent.children.count > 1
        }), let parent = slot.parent as? TilingContainer else { return false }

        let siblings = parent.children.filter { $0 !== slot }
        let capacities = siblings.map { max(0, $0.getWeight(orientation) - minimumTilingSiblingWeight) }
        let totalCapacity = capacities.reduce(0, +)
        let appliedDelta = min(requestedDelta, totalCapacity)
        guard appliedDelta > minimumTilingSizeTolerance else { return false }

        slot.setWeight(orientation, slot.getWeight(orientation) + appliedDelta)
        var remaining = appliedDelta
        for (index, sibling) in siblings.enumerated() {
            let reduction = index == siblings.indices.last
                ? remaining
                : appliedDelta * capacities[index] / totalCapacity
            sibling.setWeight(orientation, sibling.getWeight(orientation) - reduction)
            remaining -= reduction
        }
        return true
    }
}

private let minimumTilingSizeTolerance: CGFloat = 1
private let minimumTilingSizeConfirmationCount = 3
private let minimumTilingSiblingWeight: CGFloat = 1

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
