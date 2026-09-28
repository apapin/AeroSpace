@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false
    /// Simulates an app that enforces a minimum window size: `setAxFrame`
    /// never makes the window smaller than this.
    var appMinimumSizeForTest: CGSize?
    /// Frames applied through `setAxFrame`, oldest first.
    private(set) var appliedFramesForTest: [Rect] = []
    private var pendingSizeReportsForTest: [(requested: CGSize, actual: CGSize)] = []

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        _rect = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        let current = _rect ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        let topLeft = topLeft ?? current.topLeftCorner
        var actualSize = size ?? current.size
        if let minimum = appMinimumSizeForTest {
            actualSize = CGSize(width: max(actualSize.width, minimum.width), height: max(actualSize.height, minimum.height))
        }
        let frame = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: actualSize.width, height: actualSize.height)
        _rect = frame
        appliedFramesForTest.append(frame)
        if let size { pendingSizeReportsForTest.append((requested: size, actual: actualSize)) }
    }

    /// Report the sizes the app accepted since the last call, like MacApp
    /// does after each Accessibility resize. Returns true when a report would
    /// schedule another refresh session.
    @MainActor
    func reportAppliedSizesForTest() -> Bool {
        let reports = pendingSizeReportsForTest
        pendingSizeReportsForTest = []
        return reports
            .map { observeTilingSize(requested: $0.requested, actual: $0.actual) }
            .contains { $0 != .accepted }
    }
}
