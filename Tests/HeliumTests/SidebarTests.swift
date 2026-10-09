import AppKit
import XCTest
@testable import helium_terminal

final class SidebarTests: XCTestCase {
    /// Renders the sidebar offscreen; set HELIUM_SNAPSHOT=path to write a PNG for inspection.
    func testRowsFitTheirContent() throws {
        let plain = Workspace()
        let branch = Workspace(); branch.branch = "main"
        let busy = Workspace(); busy.branch = "feat/oauth-login"; busy.ports = [8080]
        busy.notification = "Dev server: Listening on :8080 and serving the docs site at /docs, "
            + "with hot reload enabled for every package in the workspace"
        let width = Double(ProcessInfo.processInfo.environment["HELIUM_SIDEBAR_WIDTH"] ?? "") ?? 260
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        sidebar.appearance = NSAppearance(named: .darkAqua)
        sidebar.update([plain, branch, busy], selected: branch)
        sidebar.layoutSubtreeIfNeeded()

        let heights = sidebar.rowHeights
        XCTAssertEqual(heights.count, 3)
        XCTAssertLessThan(heights[0], heights[1], "a 1-line row must be shorter than a 2-line row")
        XCTAssertLessThan(heights[1], heights[2], "a 2-line row must be shorter than a 4-line row")

        // Notification text wraps to the sidebar's real width: wider sidebar, fewer lines, shorter row.
        func busyRowHeight(width: CGFloat) -> CGFloat {
            let s = SidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
            s.update([busy], selected: nil)
            s.layoutSubtreeIfNeeded()
            return s.rowHeights[0]
        }
        XCTAssertLessThan(busyRowHeight(width: 520), busyRowHeight(width: 220))

        if let out = ProcessInfo.processInfo.environment["HELIUM_SNAPSHOT"] {
            let rep = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
            sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        print("row heights:", heights)
    }

    func testWaitingForInputIsRecognized() {
        for text in ["Claude Code: Claude is waiting for your input", "Claude Code: Claude needs your permission to use Bash",
                     "Codex: Waiting for approval to run npm install", "agent: needs your input", "Claude: needs input"] {
            XCTAssertTrue(Workspace.isWaitingForInput(text), text)
        }
        for text in ["Dev server: Listening on :8080", "Build finished", "Tests passed"] {
            XCTAssertFalse(Workspace.isWaitingForInput(text), text)
        }
    }
}
