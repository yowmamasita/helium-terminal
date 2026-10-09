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
        defer { LabelStore.delete("urgent"); LabelStore.delete("client") }
        LabelStore.save(TabLabel(name: "urgent", color: "Red"))
        LabelStore.save(TabLabel(name: "client", color: "Yellow"))
        branch.labels = ["urgent", "client"]
        branch.customTitle = "API work"
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
        // The idle reminder means the turn finished; it must not look like a blocked agent.
        XCTAssertTrue(Workspace.isIdleReminder("Claude Code: Claude is waiting for your input"))
        XCTAssertFalse(Workspace.isWaitingForInput("Claude Code: Claude is waiting for your input"))
        for text in ["Claude Code: Claude needs your permission to use Bash",
                     "Codex: Waiting for approval to run npm install", "agent: needs your input", "Claude: needs input",
                     "Codex: Approval requested: npm install", "Codex wants to edit src/main.rs"] {
            XCTAssertTrue(Workspace.isWaitingForInput(text), text)
        }
        for text in ["Dev server: Listening on :8080", "Build finished", "Tests passed"] {
            XCTAssertFalse(Workspace.isWaitingForInput(text), text)
        }
    }

    /// Renders an expanded and a collapsed group; HELIUM_SNAPSHOT_GROUPS=path writes a PNG.
    func testGroupsRender() throws {
        let api = TabGroup(name: "API", color: "Blue")
        let infra = TabGroup(name: "Infra", color: "Green", collapsed: true)
        let a = Workspace(); a.group = api; a.branch = "feat/oauth"
        let b = Workspace(); b.group = api
        let c = Workspace(); c.group = infra
        let d = Workspace(); d.group = infra
        let lone = Workspace()
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        sidebar.appearance = NSAppearance(named: .darkAqua)
        sidebar.update([a, b, c, d, lone], selected: a)
        sidebar.layoutSubtreeIfNeeded()
        // 2 headers + 2 API tabs + the ungrouped tab; Infra's tabs are collapsed away.
        XCTAssertEqual(sidebar.rowHeights.count, 5)
        if let out = ProcessInfo.processInfo.environment["HELIUM_SNAPSHOT_GROUPS"] {
            let rep = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
            sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}
