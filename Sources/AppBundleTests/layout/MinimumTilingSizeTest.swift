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

        assertTrue(window.learnMinimumTilingSize(
            requested: CGSize(width: 400, height: 500),
            actual: CGSize(width: 626, height: 500),
        ))

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 300),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, CGSize(width: 626, height: 300))
    }

    func testLearnedMinimumIsMonotonic() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        assertTrue(window.learnMinimumTilingSize(
            requested: CGSize(width: 300, height: 300),
            actual: CGSize(width: 626, height: 469),
        ))
        assertFalse(window.learnMinimumTilingSize(
            requested: CGSize(width: 300, height: 300),
            actual: CGSize(width: 600, height: 450),
        ))

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 300),
            within: workspaceBounds,
        )
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    func testBottomRightLeafExpandsAndShiftsInsideWorkspace() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        assertTrue(window.learnMinimumTilingSize(
            requested: CGSize(width: 365, height: 322),
            actual: CGSize(width: 626, height: 469),
        ))

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 2189, topLeftY: 1075, width: 365, height: 322),
            within: workspaceBounds,
        )
        assertEquals(resolved.topLeftCorner, CGPoint(x: 1928, y: 928))
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    func testTopLeftLeafStaysAnchoredWhenItExpands() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        assertTrue(window.learnMinimumTilingSize(
            requested: CGSize(width: 365, height: 322),
            actual: CGSize(width: 626, height: 469),
        ))

        let resolved = window.resolveTilingFrame(
            Rect(topLeftX: 0, topLeftY: 0, width: 365, height: 322),
            within: workspaceBounds,
        )
        assertEquals(resolved.topLeftCorner, .zero)
        assertEquals(resolved.size, CGSize(width: 626, height: 469))
    }

    private let workspaceBounds = Rect(topLeftX: 0, topLeftY: 0, width: 2554, height: 1397)
}
