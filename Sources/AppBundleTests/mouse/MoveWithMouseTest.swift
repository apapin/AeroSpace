@testable import AppBundle
import XCTest

@MainActor
final class MoveWithMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDropZone() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)

        assertEquals(CGPoint(x: 50, y: 50).dropZone(in: rect), .center)
        assertEquals(CGPoint(x: 10, y: 50).dropZone(in: rect), .edge(.left))
        assertEquals(CGPoint(x: 90, y: 50).dropZone(in: rect), .edge(.right))
        assertEquals(CGPoint(x: 50, y: 10).dropZone(in: rect), .edge(.up))
        assertEquals(CGPoint(x: 50, y: 90).dropZone(in: rect), .edge(.down))
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
        config.enableNormalizationBspShape = true
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
