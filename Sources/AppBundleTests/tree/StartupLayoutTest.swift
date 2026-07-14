@testable import AppBundle
import XCTest

@MainActor
final class StartupLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSmartStartupLayoutPreservesConfiguredStackRoot() {
        config.defaultRootContainerLayout = .stack
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        for id: UInt32 in 1 ... 4 {
            TestWindow.new(id: id, parent: root)
        }

        smartLayoutAtStartup(workspace)

        assertEquals(root.layout, .stack)
    }
}
