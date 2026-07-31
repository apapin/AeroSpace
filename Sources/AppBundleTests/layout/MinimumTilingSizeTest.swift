@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class MinimumTilingSizeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testUnconstrainedFrameIsUnchanged() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let requested = Rect(topLeftX: 100, topLeftY: 200, width: 500, height: 400)

        let resolved = window.resolveTilingFrame(requested, within: workspaceBounds)
        assertEquals(resolved.topLeftCorner, requested.topLeftCorner)
        assertEquals(resolved.size, requested.size)
    }

    func testRejectedDimensionsAreLearnedIndependently() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)

        confirmMinimum(window, requested: CGSize(width: 400, height: 500), actual: CGSize(width: 626, height: 500))

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 300),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, CGSize(width: 626, height: 300))
    }

    func testSingleStaleRejectionIsNotLearned() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let requested = CGSize(width: 400, height: 500)

        XCTAssertEqual(window.observeTilingSize(
            requested: requested,
            actual: CGSize(width: 626, height: 500),
        ), .retry)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: requested), .accepted)

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 100, topLeftY: 200, width: 400, height: 500),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, requested)
    }

    func testConsistentRejectionRebalancesEnclosingSplit() {
        let root = focus.workspace.rootTilingContainer
        let left = TestWindow.new(id: 1, parent: root, adaptiveWeight: 600)
        let right = TilingContainer.newVTiles(parent: root, adaptiveWeight: 400)
        let window = TestWindow.new(id: 2, parent: right, adaptiveWeight: 250)
        let bottom = TestWindow.new(id: 3, parent: right, adaptiveWeight: 250)
        confirmMinimum(
            window,
            requested: CGSize(width: 400, height: 500),
            actual: CGSize(width: 626, height: 500),
        )

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 500),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, CGSize(width: 626, height: 500))
        XCTAssertEqual(left.hWeight, 374, accuracy: 0.001)
        XCTAssertEqual(right.hWeight, 626, accuracy: 0.001)
        XCTAssertEqual(window.vWeight, 250, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 250, accuracy: 0.001)
    }

    func testLearnedMinimumIsMonotonic() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        confirmMinimum(
            window,
            requested: CGSize(width: 300, height: 300),
            actual: CGSize(width: 626, height: 469),
        )
        XCTAssertEqual(window.observeTilingSize(
            requested: CGSize(width: 300, height: 300),
            actual: CGSize(width: 600, height: 450),
        ), .accepted)

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 300),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    func testBottomRightLeafExpandsAndShiftsInsideWorkspace() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        confirmMinimum(
            window,
            requested: CGSize(width: 365, height: 322),
            actual: CGSize(width: 626, height: 469),
        )

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 2189, topLeftY: 1075, width: 365, height: 322),
            within: workspaceBounds,
        )
        assertEquals(resolved.topLeftCorner, CGPoint(x: 1928, y: 928))
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    func testTopLeftLeafStaysAnchoredWhenItExpands() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        confirmMinimum(
            window,
            requested: CGSize(width: 365, height: 322),
            actual: CGSize(width: 626, height: 469),
        )

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 0, topLeftY: 0, width: 365, height: 322),
            within: workspaceBounds,
        )
        assertEquals(resolved.topLeftCorner, .zero)
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    private func confirmMinimum(_ window: Window, requested: CGSize, actual: CGSize) {
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .retry)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .retry)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .learned)
    }

    private let workspaceBounds = Rect(topLeftX: 0, topLeftY: 0, width: 2554, height: 1397)
}
