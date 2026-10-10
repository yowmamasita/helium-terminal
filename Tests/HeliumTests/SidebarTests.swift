import AppKit
import XCTest
@testable import helium_terminal

final class SidebarTests: XCTestCase {
    /// Renders the sidebar offscreen; set HELIUM_SNAPSHOT=path to write a PNG for inspection.
    func testRowsAreAllTwoLines() throws {
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
        XCTAssertEqual(Set(heights).count, 1, "every row must be the same height: \(heights)")
        XCTAssertGreaterThan(heights[0], 30, "an empty row still reserves two lines")

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

    /// Dropping a dragged tab joins a group only inside it, or right under its expanded header.
    func testDropTarget() {
        let api = TabGroup(), infra = TabGroup(collapsed: true)
        let a = Workspace(); a.group = api
        let b = Workspace(); b.group = api
        let c = Workspace(); c.group = infra
        let lone = Workspace()
        // What the sidebar shows: API header, a, b, collapsed Infra header (c hidden), lone.
        let items: [SidebarView.Item] = [.header(api, first: a), .row(a), .row(b), .header(infra, first: c), .row(lone)]
        func check(_ slot: Int, _ before: Workspace?, _ group: TabGroup?, line: UInt = #line) {
            let t = SidebarView.dropTarget(items, slot: slot)
            XCTAssertTrue(t.before === before, "before", line: line)
            XCTAssertTrue(t.group === group, "group", line: line)
        }
        check(0, a, nil)       // above the API header: in front of the group
        check(1, a, api)       // under the expanded header
        check(2, b, api)       // between two API tabs
        check(3, c, nil)       // after API's last tab: out of the group
        check(4, lone, nil)    // under a collapsed header: after its hidden tabs, not into it
        check(5, nil, nil)     // the end
    }

    /// A menu chosen after the sidebar rebuilt (an agent's title spinner does this constantly) must still act.
    func testRowMenuWorksAfterRebuild() throws {
        final class Actions: TabGroupActions {
            var added: Workspace?
            var groups: [TabGroup] { [] }
            func addToNewGroup(_ ws: Workspace) { added = ws }
            func add(_ ws: Workspace, to group: TabGroup) {}
            func removeFromGroup(_ ws: Workspace) {}
            func toggleCollapsed(_ group: TabGroup) {}
            func ungroup(_ group: TabGroup) {}
            func closeGroup(_ group: TabGroup) {}
            func newTab(in group: TabGroup) {}
            func groupsChanged() {}
            func move(_ ws: Workspace, before: Workspace?, group: TabGroup?) {}
        }
        let actions = Actions()
        let ws = Workspace()
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        sidebar.actions = actions
        // The app's run loop drains a pool after every event; do the same between steps.
        let menu: NSMenu? = autoreleasepool {
            sidebar.update([ws], selected: ws)
            func find(_ v: NSView) -> NSMenu? { v.menu(for: NSEvent()) ?? v.subviews.lazy.compactMap(find).first }
            return find(sidebar)
        }
        autoreleasepool {
            ws.customTitle = "renamed"
            sidebar.update([ws], selected: ws)
        }
        let item = try XCTUnwrap(menu?.items.first { $0.title == "Add Tab to New Group" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertTrue(actions.added === ws)
    }

    /// If the group name popover can't show, the sidebar must not stay frozen (collapse would stop working).
    func testSidebarUpdatesWhenGroupPopoverCannotShow() {
        let g = TabGroup()
        let ws = Workspace(); ws.group = g
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500)) // no window: show fails
        sidebar.update([ws], selected: ws)
        XCTAssertEqual(sidebar.rowHeights.count, 2)
        sidebar.editGroup(g)
        g.collapsed = true
        sidebar.update([ws], selected: nil)
        XCTAssertEqual(sidebar.rowHeights.count, 1, "the collapsed group's tab must be hidden")
    }

    /// "Add Tab to Group" must not act on a group that went away while the menu was open.
    func testAddToGroupIgnoresAGroupThatWentAway() throws {
        final class Actions: TabGroupActions {
            var groups: [TabGroup] = []
            var addedTo: TabGroup?
            func addToNewGroup(_ ws: Workspace) {}
            func add(_ ws: Workspace, to group: TabGroup) { addedTo = group }
            func removeFromGroup(_ ws: Workspace) {}
            func toggleCollapsed(_ group: TabGroup) {}
            func ungroup(_ group: TabGroup) {}
            func closeGroup(_ group: TabGroup) {}
            func newTab(in group: TabGroup) {}
            func groupsChanged() {}
            func move(_ ws: Workspace, before: Workspace?, group: TabGroup?) {}
        }
        let a = TabGroup(name: "A"), b = TabGroup(name: "B")
        let actions = Actions()
        actions.groups = [a, b]
        let ws = Workspace()
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        sidebar.actions = actions
        sidebar.update([ws], selected: ws)
        func find(_ v: NSView) -> NSMenu? { v.menu(for: NSEvent()) ?? v.subviews.lazy.compactMap(find).first }
        let menu = try XCTUnwrap(find(sidebar))
        let sub = try XCTUnwrap(menu.items.first { $0.title == "Add Tab to Group" }?.submenu)
        actions.groups = [b] // A's last tab closed while the menu was open
        for title in ["A", "B"] {
            let item = try XCTUnwrap(sub.items.first { $0.title == title })
            NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        }
        XCTAssertTrue(actions.addedTo === b)
    }
}
