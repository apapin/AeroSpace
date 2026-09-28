@testable import AppBundle
import Common
import XCTest

@MainActor
final class BalanceSizesCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testBalanceSizesCommand() async {
        let workspace = Workspace.get(byName: name).apply { wsp in
            wsp.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 1)
                TestWindow.new(id: 2, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 2)
                TestWindow.new(id: 3, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 3)
            }
        }

        await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(name), .emptyStdin)

        for window in workspace.rootTilingContainer.children {
            assertEquals(window.getWeight(workspace.rootTilingContainer.orientation), 1)
        }
    }

    func testBalanceSizesMeasuresMinimumSizesAgain() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        for _ in 0 ..< 3 {
            window.observeTilingSize(requested: CGSize(width: 960, height: 1079), actual: CGSize(width: 1200, height: 1079))
        }
        assertEquals(window.minimumTilingSize, CGSize(width: 1200, height: 0))

        await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(name), .emptyStdin)

        assertEquals(window.minimumTilingSize, .zero)
    }
}
