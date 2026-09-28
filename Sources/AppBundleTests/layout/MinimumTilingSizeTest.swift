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

    func testLearnedMinimumReservesSpaceInEnclosingSplit() async throws {
        let root = focus.workspace.rootTilingContainer
        let left = TestWindow.new(id: 1, parent: root, adaptiveWeight: 600)
        let right = TilingContainer.newVTiles(parent: root, adaptiveWeight: 400)
        let window = TestWindow.new(id: 2, parent: right, adaptiveWeight: 250)
        let bottom = TestWindow.new(id: 3, parent: right, adaptiveWeight: 250)
        confirmMinimum(
            window,
            requested: CGSize(width: 860, height: 539),
            actual: CGSize(width: 1100, height: 539),
        )

        try await focus.workspace.layoutWorkspace()

        XCTAssertEqual(left.hWeight, 820, accuracy: 0.001)
        XCTAssertEqual(right.hWeight, 1100, accuracy: 0.001)
        XCTAssertEqual(window.vWeight, bottom.vWeight, accuracy: 0.001)
        assertEquals(left.appliedFramesForTest.last?.frameForTest, [0, 0, 820, 1079])
        assertEquals(window.appliedFramesForTest.last?.frameForTest, [820, 0, 1100, 539.5])
        assertEquals(bottom.appliedFramesForTest.last?.frameForTest, [820, 539.5, 1100, 539.5])
    }

    func testNestedSplitReservesTheSumOfItsMinimums() async throws {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let nested = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1)
        let second = TestWindow.new(id: 2, parent: nested)
        let third = TestWindow.new(id: 3, parent: nested)
        for window in [second, third] {
            confirmMinimum(window, requested: CGSize(width: 480, height: 1079), actual: CGSize(width: 600, height: 1079))
        }

        try await focus.workspace.layoutWorkspace()

        XCTAssertEqual(first.hWeight, 720, accuracy: 0.001)
        XCTAssertEqual(nested.hWeight, 1200, accuracy: 0.001)
        assertEquals(second.appliedFramesForTest.last?.frameForTest, [720, 0, 600, 1079])
        assertEquals(third.appliedFramesForTest.last?.frameForTest, [1320, 0, 600, 1079])
    }

    func testReservationAccountsForInnerGaps() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
        let root = focus.workspace.rootTilingContainer
        let constrained = TestWindow.new(id: 1, parent: root)
        let other = TestWindow.new(id: 2, parent: root)
        confirmMinimum(constrained, requested: CGSize(width: 955, height: 1079), actual: CGSize(width: 1200, height: 1079))

        try await focus.workspace.layoutWorkspace()

        assertEquals(constrained.appliedFramesForTest.last?.frameForTest, [0, 0, 1200, 1079])
        assertEquals(other.appliedFramesForTest.last?.frameForTest, [1210, 0, 710, 1079])
    }

    func testConstrainedWindowSettlesWithoutOverlap() async throws {
        let root = focus.workspace.rootTilingContainer
        let constrained = TestWindow.new(id: 1, parent: root)
        let other = TestWindow.new(id: 2, parent: root)
        constrained.appMinimumSizeForTest = CGSize(width: 1200, height: 0)

        let passes = try await layoutUntilSettled([constrained, other])

        XCTAssertLessThanOrEqual(passes, 5)
        assertEquals(constrained.appliedFramesForTest.last?.frameForTest, [0, 0, 1200, 1079])
        assertEquals(other.appliedFramesForTest.last?.frameForTest, [1200, 0, 720, 1079])
    }

    /// Two neighbors whose minimums cannot both fit used to trade space back
    /// and forth forever, each layout pass scheduling the next one.
    func testNeighborsWithUnsatisfiableMinimumsSettle() async throws {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        first.appMinimumSizeForTest = CGSize(width: 1100, height: 0)
        second.appMinimumSizeForTest = CGSize(width: 1100, height: 0)

        let passes = try await layoutUntilSettled([first, second])

        XCTAssertLessThanOrEqual(passes, 5)
        XCTAssertEqual(first.hWeight, 960, accuracy: 0.001)
        XCTAssertEqual(second.hWeight, 960, accuracy: 0.001)
        // The overlap is unavoidable, but each window stays inside the workspace.
        assertEquals(first.appliedFramesForTest.last?.frameForTest, [0, 0, 1100, 1079])
        assertEquals(second.appliedFramesForTest.last?.frameForTest, [820, 0, 1100, 1079])
    }

    func testUnsettledProbesStopSchedulingRefreshes() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let requested = CGSize(width: 400, height: 500)
        for step in 0 ..< 8 {
            let actual = CGSize(width: 600 + CGFloat(step) * 10, height: 500)
            XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .retry)
        }
        let settled = CGSize(width: 700, height: 500)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: settled), .accepted)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: settled), .accepted)
        // Consistent reports are still learned after the probe budget is spent.
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: settled), .learned)
        assertEquals(window.minimumTilingSize, CGSize(width: 700, height: 0))

        // An accepted size ends the streak, so the next rejection probes again.
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: requested), .accepted)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: CGSize(width: 800, height: 500)), .retry)
    }

    func testForgottenMinimumIsMeasuredAgain() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        confirmMinimum(window, requested: CGSize(width: 400, height: 500), actual: CGSize(width: 626, height: 500))

        window.forgetMinimumTilingSize()

        assertEquals(window.minimumTilingSize, .zero)
        let requested = Rect(topLeftX: 100, topLeftY: 200, width: 400, height: 500)
        assertEquals(window.resolveTilingFrame(requested, within: workspaceBounds).size, requested.size)
        XCTAssertEqual(window.observeTilingSize(requested: requested.size, actual: CGSize(width: 500, height: 500)), .retry)
    }

    func testAllocationFundsDeficitsFromSurplusInProportion() {
        let minimums: [CGFloat] = [800, 0, 600]
        let result = allocateTilingLengths([500, 700, 800], minimums: minimums, total: 2000)

        XCTAssertEqual(result[0], 800, accuracy: 0.001)
        XCTAssertEqual(result[1], 700 - 700.0 / 3, accuracy: 0.001)
        XCTAssertEqual(result[2], 800 - 200.0 / 3, accuracy: 0.001)
        XCTAssertEqual(result.reduce(0, +), 2000, accuracy: 0.001)
        assertEquals(allocateTilingLengths(result, minimums: minimums, total: 2000), result)
    }

    func testAllocationLeavesSatisfiedLengthsUnchanged() {
        assertEquals(allocateTilingLengths([1000, 920], minimums: [800, 0], total: 1920), [1000, 920])
    }

    func testAllocationSharesInProportionToClaimsWhenMinimumsDoNotFit() {
        assertEquals(allocateTilingLengths([1500, 420], minimums: [1100, 1100], total: 1920), [960, 960])

        let minimums: [CGFloat] = [600, 0, 600]
        let result = allocateTilingLengths([300, 300, 300], minimums: minimums, total: 900)
        assertEquals(result, [360, 180, 360])
        assertEquals(allocateTilingLengths(result, minimums: minimums, total: 900), result)
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

    /// Run layout passes the way refresh sessions would. A pass whose resizes
    /// report a probe or a newly learned minimum schedules another pass, and
    /// the layout has settled once a pass neither does that nor moves a window.
    private func layoutUntilSettled(_ windows: [TestWindow], maxPasses: Int = 12) async throws -> Int {
        var previousFrames: [[CGFloat]?] = []
        for pass in 1 ... maxPasses {
            try await focus.workspace.layoutWorkspace()
            let frames = windows.map { $0.appliedFramesForTest.last?.frameForTest }
            let needsRefresh = windows.map { $0.reportAppliedSizesForTest() }.contains(true)
            if !needsRefresh && frames == previousFrames { return pass }
            previousFrames = frames
        }
        XCTFail("Layout did not settle after \(maxPasses) passes")
        return maxPasses
    }

    private func confirmMinimum(_ window: Window, requested: CGSize, actual: CGSize) {
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .retry)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .retry)
        XCTAssertEqual(window.observeTilingSize(requested: requested, actual: actual), .learned)
    }

    private let workspaceBounds = Rect(topLeftX: 0, topLeftY: 0, width: 2554, height: 1397)
}

extension Rect {
    fileprivate var frameForTest: [CGFloat] { [topLeftX, topLeftY, width, height] }
}
