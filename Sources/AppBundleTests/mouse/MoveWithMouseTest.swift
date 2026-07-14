@testable import AppBundle
import XCTest

@MainActor
final class MoveWithMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testResizeGestureCannotBecomeAMouseDrop() {
        defer { resetMouseManipulationTracking() }

        assertTrue(beginMoveManipulation(windowId: 1))
        assertEquals(currentMouseManipulationKind, .move)

        beginResizeManipulation(windowId: 1)
        assertEquals(currentMouseManipulationKind, .resize)
        assertEquals(currentlyManipulatedWithMouseWindowId, 1)
        assertFalse(beginMoveManipulation(windowId: 1))
        assertEquals(currentMouseManipulationKind, .resize)
    }

    func testDropZone() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)

        assertEquals(CGPoint(x: 50, y: 50).dropZone(in: rect), .center)
        assertEquals(CGPoint(x: 10, y: 50).dropZone(in: rect), .edge(.left))
        assertEquals(CGPoint(x: 90, y: 50).dropZone(in: rect), .edge(.right))
        assertEquals(CGPoint(x: 50, y: 10).dropZone(in: rect), .edge(.up))
        assertEquals(CGPoint(x: 50, y: 90).dropZone(in: rect), .edge(.down))
    }

    func testCenterDropPlanDoesNotMutateUntilCommit() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let source = TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: targetRect.center,
        )

        XCTAssertEqual(plan?.operation, .swap(targetWindowId: 2))
        XCTAssertEqual(plan?.previewRect?.topLeftX, 100)
        XCTAssertEqual(plan?.previewRect?.topLeftY, 200)
        XCTAssertEqual(plan?.previewRect?.width, 800)
        XCTAssertEqual(plan?.previewRect?.height, 600)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))

        commitMouseDropPlan(plan!)

        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    func testEdgeDropPlanPreviewsHalfAndMutatesOnceCommitted() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let source = TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: CGPoint(x: 899, y: 500),
        )

        XCTAssertEqual(plan?.operation, .warp(targetWindowId: 2, direction: .right))
        XCTAssertEqual(plan?.previewRect?.topLeftX, 500)
        XCTAssertEqual(plan?.previewRect?.topLeftY, 200)
        XCTAssertEqual(plan?.previewRect?.width, 400)
        XCTAssertEqual(plan?.previewRect?.height, 600)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))

        commitMouseDropPlan(plan!)

        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    func testDropWithoutAValidTargetOnSameWorkspaceCancels() {
        let workspace = Workspace.get(byName: name)
        let source = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: nil,
            targetRect: nil,
            location: .zero,
        )

        XCTAssertNil(plan)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testStackCenterDropCreatesAStackOnlyOnCommit() {
        config.mouseDropAction = .stack
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let source = TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)
        target.setWeight(.h, 3)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: targetRect.center,
        )

        XCTAssertEqual(plan?.operation, .stack(targetWindowId: 2))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))

        commitMouseDropPlan(plan!)

        assertEquals(
            root.layoutDescription,
            .h_tiles([.stack([.window(2), .window(1)]), .window(3)]),
        )
        XCTAssertEqual(root.children[0].getWeight(.h), 3)
    }

    func testCenterSwapExchangesSingletonWithEntireStack() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let source = TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .h, .stack, index: INDEX_BIND_LAST)
        let target = TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: stack)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: targetRect.center,
        )
        commitMouseDropPlan(plan!)

        assertEquals(
            root.layoutDescription,
            .h_tiles([.stack([.window(2), .window(3)]), .window(1)]),
        )
    }

    func testCenterDropFromMultiWindowStackIsNotEligible() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .h, .stack, index: INDEX_BIND_LAST)
        let source = TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        let target = TestWindow.new(id: 3, parent: root)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: targetRect.center,
        )

        XCTAssertNil(plan)
    }

    func testEdgeDropExtractsOneWindowFromStack() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .h, .stack, index: INDEX_BIND_LAST)
        let source = TestWindow.new(id: 1, parent: stack)
        TestWindow.new(id: 2, parent: stack)
        let target = TestWindow.new(id: 3, parent: root)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: CGPoint(x: 500, y: 799),
        )
        commitMouseDropPlan(plan!)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .stack([.window(2)]),
                .v_tiles([.window(3), .window(1)]),
            ]),
        )

        config.enableNormalizationFlattenContainers = true
        workspace.normalizeContainers()
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(2),
                .v_tiles([.window(3), .window(1)]),
            ]),
        )
    }

    func testEdgeDropSplitsBesideTheWholeTargetStack() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let source = TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 1, .h, .stack, index: INDEX_BIND_LAST)
        let target = TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: stack)
        let targetRect = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)

        let plan = makeMouseDropPlan(
            source: source,
            targetWorkspace: workspace,
            target: target,
            targetRect: targetRect,
            location: CGPoint(x: 500, y: 201),
        )
        commitMouseDropPlan(plan!)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .v_tiles([.window(1), .stack([.window(2), .window(3)])]),
            ]),
        )
    }

    func testPerpendicularDropCreatesDirectionalSplit() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let dragged = TestWindow.new(id: 3, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .up)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(3), .window(2)]),
            ]),
        )
    }

    func testPositiveDropPlacesDraggedWindowAfterTarget() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let dragged = TestWindow.new(id: 3, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .down)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testSameAxisDropSplitsTargetSlotWithoutAddingThirdSibling() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let dragged = TestWindow.new(id: 3, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .left)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .h_tiles([.window(3), .window(2)]),
            ]),
        )
    }

    func testSameAxisDropSurvivesOppositeOrientationNormalization() {
        config.enableBspLayout = false
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let dragged = TestWindow.new(id: 3, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .left)
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .h_tiles([.window(3), .window(2)]),
            ]),
        )
    }

    func testDropMovesWindowAcrossSubtrees() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let source = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: source)
        let dragged = TestWindow.new(id: 2, parent: source)
        let target = TestWindow.new(id: 3, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .down)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .v_tiles([.window(1)]),
                .v_tiles([.window(3), .window(2)]),
            ]),
        )
    }

    func testRepeatedDropIsIdempotent() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let target = TestWindow.new(id: 1, parent: root)
        let dragged = TestWindow.new(id: 2, parent: root)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .down)
        let first = root.layoutDescription
        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .down)

        assertEquals(root.layoutDescription, first)
    }

    func testWrapperInheritsTargetWeight() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        let dragged = TestWindow.new(id: 3, parent: root)
        target.setWeight(.h, 3)

        reparentWindowForMouseDrop(dragged, relativeTo: target, direction: .up)

        let wrapper = root.children[1] as? TilingContainer
        XCTAssertNotNil(wrapper)
        XCTAssertEqual(wrapper?.getWeight(.h), 3)
    }
}
