@testable import AppBundle
import Common
import XCTest

@MainActor
final class BspCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableBspLayout = true
    }

    func testMoveSwapsWithTheNeighboringSlot() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 600)
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1320)
        TestWindow.new(id: 2, parent: column, adaptiveWeight: 400)
        let third = TestWindow.new(id: 3, parent: column, adaptiveWeight: 680)
        assertEquals(third.focusWindow(), true)

        let result = await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .v_tiles([.window(2), .window(1)])]))
        // The slots keep their geometry; only the windows trade places.
        XCTAssertEqual(third.hWeight, 600)
        XCTAssertEqual(first.vWeight, 680)
        assertEquals(focus.windowOrNil?.windowId, 3)
    }

    func testMoveSwapsWithinTheSplit() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: column)
        assertEquals(TestWindow.new(id: 3, parent: column).focusWindow(), true)

        await parseCommand("move up").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(3), .window(2)])]))
    }

    func testMoveAtTheWorkspaceEdgeUsesTheBoundaryAction() async {
        config.bspAutoBalance = .ancestors
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: column)
        let third = TestWindow.new(id: 3, parent: column)
        assertEquals(third.focusWindow(), true)

        await parseCommand("move down").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .v_tiles([.h_tiles([.window(1), .v_tiles([.window(2)])]), .window(3)]),
        )
        // Every window keeps an equal share of the workspace.
        XCTAssertEqual(root.vWeight, 720, accuracy: 0.001)
        XCTAssertEqual(third.vWeight, 360, accuracy: 0.001)
    }

    func testMoveAtTheWorkspaceEdgeCanFail() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)
        TestWindow.new(id: 2, parent: root)

        let result = await parseCommand("move --boundaries-action fail left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testMoveNodeToWorkspaceSplitsTheTargetsMostRecentWindow() async {
        let targetRoot = Workspace.get(byName: "b").rootTilingContainer
        TestWindow.new(id: 10, parent: targetRoot)
        TestWindow.new(id: 11, parent: targetRoot)
        Workspace.get(byName: "a").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }

        await parseCommand("move-node-to-workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(targetRoot.layoutDescription, .h_tiles([.window(10), .v_tiles([.window(11), .window(1)])]))
    }

    func testMoveNodeToWorkspaceRebalancesTheSourceWorkspace() async {
        config.bspAutoBalance = .ancestors
        let sourceRoot = Workspace.get(byName: "a").rootTilingContainer
        let first = TestWindow.new(id: 1, parent: sourceRoot, adaptiveWeight: 300)
        let column = TilingContainer.newVTiles(parent: sourceRoot, adaptiveWeight: 1620)
        TestWindow.new(id: 2, parent: column)
        assertEquals(TestWindow.new(id: 3, parent: column).focusWindow(), true)

        await parseCommand("move-node-to-workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(first.hWeight, 960, accuracy: 0.001)
        XCTAssertEqual(column.hWeight, 960, accuracy: 0.001)
        assertEquals((Workspace.get(byName: "b").rootTilingContainer.children.singleOrNil() as? Window)?.windowId, 3)
    }
}
