@testable import AppBundle
import XCTest

@MainActor
final class BspTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableBspLayout = true
    }

    func testLongestSidePolicy() {
        XCTAssertEqual(
            longestSideBspOrientation(Rect(topLeftX: 0, topLeftY: 0, width: 1200, height: 800)),
            .h,
        )
        XCTAssertEqual(
            longestSideBspOrientation(Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 900)),
            .v,
        )
        XCTAssertEqual(
            longestSideBspOrientation(Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 800)),
            .h,
        )
    }

    func testDirectInsertionSplitsTargetImmediately() {
        let root = focus.workspace.rootTilingContainer
        let target = TestWindow.new(id: 1, parent: root)
        target.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 1200, height: 800)
        let inserted = TestWindow.new(id: 2, parent: root)

        insertWindowUsingBsp(inserted, splitting: target)

        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testDirectInsertionUsesTargetLeafLongestSide() {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let target = TestWindow.new(id: 2, parent: root)
        root.setBspOrientation(.h)
        first.setWeight(.h, 1)
        target.setWeight(.h, 1)
        target.lastAppliedLayoutVirtualRect = Rect(topLeftX: 1000, topLeftY: 0, width: 500, height: 900)
        let inserted = TestWindow.new(id: 3, parent: root)

        insertWindowUsingBsp(inserted, splitting: target)

        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testDirectInsertionPreservesTargetsOuterWeight() {
        let root = focus.workspace.rootTilingContainer
        let target = TestWindow.new(id: 1, parent: root)
        let sibling = TestWindow.new(id: 2, parent: root)
        target.setWeight(.h, 580)
        sibling.setWeight(.h, 1340)
        target.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 580, height: 1080)
        let inserted = TestWindow.new(id: 3, parent: root)

        insertWindowUsingBsp(inserted, splitting: target)

        let wrapper = root.children[0] as? TilingContainer
        XCTAssertNotNil(wrapper)
        XCTAssertEqual(wrapper?.getWeight(.h), 580)
        XCTAssertEqual(sibling.getWeight(.h), 1340)
    }

    func testEstimatedRectWorksBeforeFirstLayoutPass() {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        root.setBspOrientation(.h)
        first.setWeight(.h, 1)
        second.setWeight(.h, 1)

        let estimated = second.estimatedTilingRect()

        XCTAssertNotNil(estimated)
        XCTAssertLessThan(estimated!.width, estimated!.height)
    }

    func testRepairPassOnlyRepairsNaryTilesNodes() {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        for id: UInt32 in 1 ... 5 {
            TestWindow.new(id: id, parent: root)
        }

        workspace.normalizeContainers()

        func assertBinary(_ container: TilingContainer) {
            if container.layout == .tiles {
                XCTAssertLessThanOrEqual(container.children.count, 2)
            }
            for child in container.children {
                if let child = child as? TilingContainer {
                    assertBinary(child)
                }
            }
        }
        assertBinary(workspace.rootTilingContainer)
    }

    func testBspDisabledLeavesNaryNodeUntouched() {
        config.enableBspLayout = false
        config.enableNormalizationFlattenContainers = false
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        for id: UInt32 in 1 ... 3 {
            TestWindow.new(id: id, parent: root)
        }

        workspace.normalizeContainers()

        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    func testAccordionIsAnEscapeIsland() {
        let workspace = focus.workspace
        let accordion = TilingContainer(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: 1,
            .h,
            .accordion,
            index: INDEX_BIND_LAST,
        )
        for id: UInt32 in 1 ... 3 {
            TestWindow.new(id: id, parent: accordion)
        }

        workspace.normalizeContainers()

        assertEquals(
            accordion.layoutDescription,
            .h_accordion([.window(1), .window(2), .window(3)]),
        )
    }

    func testBspModeDoesNotForceOppositeNestedOrientations() {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.setBspOrientation(.h)
        let child = TilingContainer(
            parent: root,
            adaptiveWeight: 1,
            .h,
            .tiles,
            index: INDEX_BIND_LAST,
        )
        TestWindow.new(id: 1, parent: child)
        TestWindow.new(id: 2, parent: child)

        workspace.normalizeContainers()

        XCTAssertEqual(child.orientation, .h)
    }
}
