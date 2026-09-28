@testable import AppBundle
import Common
import XCTest

@MainActor
final class IgnoredMonitorsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseIgnoredMonitors() {
        let result = parseConfig(
            """
            ignored-monitors = ['xeneon', '^dashboard$']
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.ignoredMonitors.map(\.origin), ["xeneon", "^dashboard$"])
        assertEquals(defaultConfig.ignoredMonitors, [])
    }

    func testParseIgnoredMonitorsRejectsNonNamePatterns() {
        let unsupported = "'main', 'secondary' and monitor numbers are not supported here"
        for pattern in ["main", "secondary", "2", ""] {
            let result = parseConfig("ignored-monitors = ['xeneon', '\(pattern)']")
            assertEquals(result.strErrors, [
                "[ERROR] ignored-monitors[1]: Expected a monitor name pattern, got '\(pattern)'. \(unsupported)",
            ])
        }
        assertEquals(parseConfig("ignored-monitors = [3]").strErrors, [
            "[ERROR] ignored-monitors[0]: \(expectedActualTypeError(expected: .string, actual: .int))",
        ])
        let invalidRegex = parseConfig("ignored-monitors = ['(']").strErrors
        assertEquals(invalidRegex.count, 1)
        assertTrue(invalidRegex.first?.starts(with: "[ERROR] ignored-monitors[0]: Can't parse '(' regex") == true)
    }

    func testIgnoredMonitorsAreNotManaged() {
        let patterns = [CaseInsensitiveRegex.new("xeneon").getOrDie()]
        let main = FakeMonitor(name: "AW3225QF", Rect(topLeftX: 0, topLeftY: 0, width: 3840, height: 2160))
        let edge = FakeMonitor(name: "XENEON EDGE", Rect(topLeftX: 3840, topLeftY: 0, width: 720, height: 2560))
        let side = FakeMonitor(name: "LC32G7xT", Rect(topLeftX: -2560, topLeftY: 991, width: 2560, height: 1440))

        assertEquals(managedMonitors([main, edge, side], ignoring: patterns).map(\.name), ["AW3225QF", "LC32G7xT"])
        assertEquals(managedMonitors([main, edge, side], ignoring: []).map(\.name), ["AW3225QF", "XENEON EDGE", "LC32G7xT"])
        // AeroSpace needs a monitor, so it keeps the ignored ones when nothing else is connected.
        assertEquals(managedMonitors([edge], ignoring: patterns).map(\.name), ["XENEON EDGE"])
    }

    func testManagedMainMonitorSkipsAnIgnoredMainDisplay() {
        // macOS moves the origin to another display when the main display disconnects.
        let edge = FakeMonitor(name: "XENEON EDGE", Rect(topLeftX: 0, topLeftY: 0, width: 720, height: 2560))
        let side = FakeMonitor(name: "LC32G7xT", Rect(topLeftX: -2560, topLeftY: 991, width: 2560, height: 1440))
        let main = FakeMonitor(name: "AW3225QF", Rect(topLeftX: 0, topLeftY: 0, width: 3840, height: 2160))

        assertEquals(resolveManagedMainMonitor(main: edge, managed: [side]).name, "LC32G7xT")
        assertEquals(resolveManagedMainMonitor(main: main, managed: [side, main]).name, "AW3225QF")
    }

    func testSecondaryResolvesAmongManagedMonitors() {
        let main = FakeMonitor(name: "AW3225QF", Rect(topLeftX: 0, topLeftY: 0, width: 3840, height: 2160))
        let side = FakeMonitor(name: "LC32G7xT", Rect(topLeftX: -2560, topLeftY: 991, width: 2560, height: 1440))

        // With the dashboard panel ignored, two managed monitors remain.
        let managed = [side, main]
        assertEquals(MonitorDescription.secondary.resolveMonitor(sortedMonitors: managed, mainMonitor: main)?.name, "LC32G7xT")
        assertEquals(MonitorDescription.main.resolveMonitor(sortedMonitors: managed, mainMonitor: main)?.name, "AW3225QF")
        // With only one managed monitor left, 'secondary' doesn't resolve.
        assertNil(MonitorDescription.secondary.resolveMonitor(sortedMonitors: [side], mainMonitor: side))
    }

    func testLayoutIsSuspendedWhenOnlyIgnoredMonitorsAreConnected() {
        XCTAssertFalse(isLayoutSuspendedOnIgnoredMonitors)
        config.ignoredMonitors = [CaseInsensitiveRegex.new("^test monitor$").getOrDie()]
        XCTAssertTrue(isLayoutSuspendedOnIgnoredMonitors)
        // The model still has a monitor to hold the workspaces.
        assertEquals(monitors.map(\.name), ["Test Monitor"])
        config.ignoredMonitors = [CaseInsensitiveRegex.new("xeneon").getOrDie()]
        XCTAssertFalse(isLayoutSuspendedOnIgnoredMonitors)
    }
}

private struct FakeMonitor: Monitor {
    let name: String
    let rect: Rect

    init(name: String, _ rect: Rect) {
        self.name = name
        self.rect = rect
    }

    var monitorAppKitNsScreenScreensId: Int { 1 }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var isMain: Bool { rect.topLeftCorner == .zero }
}
