import AppKit
import XCTest
@testable import helium_terminal

final class SidebarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

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

    func testAttentionColorsPersistAndReset() {
        defer { Attention.reset() }
        Attention.working.color = .systemPurple
        XCTAssertEqual(Attention.working.color, .systemPurple)
        XCTAssertEqual(Attention.waiting.color, .systemOrange)
        Attention.reset()
        XCTAssertEqual(Attention.working.color, .systemBlue)
    }

    func testWorkingAgentIsRecognized() {
        for t in ["◐ Fix the build", "◑ Fix the build", "⠋ codex", "⠐ Fix the build"] {
            XCTAssertTrue(Workspace.isWorking(title: t), t)
        }
        for t in ["✳ Fix the build", "zsh", "", "⠀ blank braille"] {
            XCTAssertFalse(Workspace.isWorking(title: t), t)
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

    /// Exercise row lifting and drop placement without posting events to the owner's desktop.
    func testDragReordersRowsAfterSelectionChange() throws {
        final class TrackingWindow: NSWindow {
            var events: [NSEvent] = []
            override func trackEvents(matching mask: NSEvent.EventTypeMask, timeout: TimeInterval,
                                      mode: RunLoop.Mode,
                                      handler: (NSEvent?, UnsafeMutablePointer<ObjCBool>) -> Void) {
                var stop: ObjCBool = false
                for event in events {
                    handler(event, &stop)
                    if stop.boolValue { break }
                }
            }
        }
        final class Actions: TabGroupActions {
            var moved: Workspace?
            var before: Workspace?
            var groups: [TabGroup] { [] }
            func addToNewGroup(_ ws: Workspace) {}
            func add(_ ws: Workspace, to group: TabGroup) {}
            func removeFromGroup(_ ws: Workspace) {}
            func toggleCollapsed(_ group: TabGroup) {}
            func ungroup(_ group: TabGroup) {}
            func closeGroup(_ group: TabGroup) {}
            func newTab(in group: TabGroup) {}
            func groupsChanged() {}
            func move(_ ws: Workspace, before: Workspace?, group: TabGroup?) {
                moved = ws
                self.before = before
            }
        }
        _ = NSApplication.shared
        let window = TrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        let sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
        let tabs = [Workspace(), Workspace(), Workspace()]
        let actions = Actions()
        sidebar.actions = actions
        sidebar.onSelect = { [weak sidebar] in sidebar?.update(tabs, selected: $0) }
        sidebar.update(tabs, selected: tabs[1])
        window.layoutIfNeeded()
        func findRows(_ view: NSView) -> [NSView] {
            if view.accessibilityRole() == .button { return [view] }
            return view.subviews.flatMap(findRows)
        }
        let rows = findRows(sidebar)
        XCTAssertEqual(rows.count, 3)
        let first = try XCTUnwrap(rows.first)
        let last = try XCTUnwrap(rows.last)
        let start = first.convert(NSPoint(x: 100, y: first.bounds.midY), to: nil)
        let end = NSPoint(x: start.x, y: last.convert(.zero, to: nil).y - 40)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }
        window.events = try [event(.leftMouseDragged, end), event(.leftMouseUp, end)]
        first.mouseDown(with: try event(.leftMouseDown, start))
        XCTAssertTrue(actions.moved === tabs[0])
        XCTAssertNil(actions.before)
        XCTAssertNil(first.shadow)
        XCTAssertEqual(first.layer?.shadowOpacity, 0)
        XCTAssertEqual(first.layer?.backgroundColor,
                       NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor,
                       "a reused row must not keep the lifted drag background")
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

    /// A menu stays actionable while an agent updates the title.
    func testRowMenuWorksAfterMetadataUpdates() throws {
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

    /// A click on a row's text (title, cwd, chips) must select the tab, like a click on its empty space.
    func testClickOnRowTextSelectsTab() throws {
        let ws = Workspace(); ws.customTitle = "a long title to click on"
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.update([ws], selected: nil)
        sidebar.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSTextField? {
            (v as? NSTextField).flatMap { $0.stringValue == ws.title ? $0 : nil } ?? v.subviews.lazy.compactMap(find).first
        }
        let title = try XCTUnwrap(find(sidebar))
        let p = title.convert(NSPoint(x: 10, y: title.bounds.midY), to: nil)
        let hit = try XCTUnwrap(sidebar.hitTest(sidebar.convert(p, from: nil)))
        XCTAssertFalse(hit is NSTextField, "the title label must not take the click")
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "a click must select even when the window isn't key")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testMetadataUpdatesPreserveRowsAndControls() throws {
        let ws = Workspace()
        ws.customTitle = "initial"
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        sidebar.update([ws], selected: nil)
        let row = try XCTUnwrap(descendants(sidebar).first { $0 is Row })
        let controls = descendants(row)
        for index in 0..<200 {
            ws.customTitle = "title \(index)"
            ws.ports = [8000 + index]
            ws.notification = "notification \(index)"
            sidebar.update([ws], selected: ws)
        }
        let current = descendants(row)
        XCTAssertEqual(current.count, controls.count)
        XCTAssertTrue(zip(current, controls).allSatisfy { $0 === $1 })
        XCTAssertTrue(descendants(sidebar).contains { $0 === row })
        XCTAssertEqual(row.accessibilityLabel(), "title 199")
        XCTAssertEqual(row.toolTip, "notification 199")
        let labels = current.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("title 199"))
        XCTAssertTrue(labels.contains(":8199"))
        XCTAssertTrue(labels.contains("⌘1"))
        XCTAssertEqual(row.layer?.backgroundColor,
                       NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor)
    }

    func testMetadataUpdatesPreserveLiveRenameEditor() throws {
        _ = NSApplication.shared
        let ws = Workspace(); ws.customTitle = "initial"
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.update([ws], selected: nil)
        sidebar.rename(ws)
        let title = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? NSTextField }
            .first { $0.currentEditor() != nil })
        let editor = try XCTUnwrap(title.currentEditor())
        editor.string = "unfinished rename"
        editor.selectedRange = NSRange(location: 4, length: 3)
        for index in 0..<100 {
            ws.customTitle = "background \(index)"
            sidebar.update([ws], selected: ws)
        }
        XCTAssertTrue(title.currentEditor() === editor)
        XCTAssertEqual(editor.string, "unfinished rename")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 3))
        window.makeFirstResponder(nil)
        sidebar.update([ws], selected: ws)
        XCTAssertEqual(ws.customTitle, "unfinished rename")
        XCTAssertFalse(title.isEditable)
        XCTAssertFalse(title.isSelectable)
        XCTAssertFalse(title.drawsBackground)
        XCTAssertEqual(title.stringValue, "unfinished rename")
    }

    func testRowMetadataUpdatesCwdLabelsAndAttentionInPlace() throws {
        let ws = Workspace()
        let group = TabGroup(name: "API", color: "Blue")
        func model(_ title: String, cwd: String, waiting: Bool, unread: Bool = false,
                   working: Bool = false, labels: [TabLabel] = []) -> Row.Model {
            Row.Model(ws: ws, index: 2, title: title, cwd: cwd, ports: [8080],
                      notification: "latest news", unread: unread, waiting: waiting, working: working,
                      selected: false, labels: labels, group: group)
        }
        let row = Row(model("initial", cwd: "/demo/initial", waiting: false)) {}
        let controls = descendants(row)
        for index in 0..<100 {
            row.update(model("spinner \(index)", cwd: "/demo/\(index)", waiting: true))
        }
        XCTAssertTrue(zip(descendants(row), controls).allSatisfy { $0 === $1 })
        XCTAssertEqual(row.accessibilityLabel(), "spinner 99, needs input")
        XCTAssertEqual(row.toolTip, "latest news")
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "/demo/99" })
        let edge = try XCTUnwrap(row.subviews.first { $0.layer?.backgroundColor == Attention.waiting.color.cgColor })
        XCTAssertFalse(edge.isHidden)
        defer { Attention.reset() }
        Attention.waiting.color = .systemPurple
        row.refreshColors()
        XCTAssertEqual(edge.layer?.backgroundColor, NSColor.systemPurple.cgColor)
        row.update(model("done", cwd: "/demo/final", waiting: false, unread: true,
                         labels: [TabLabel(name: "urgent", color: "Red")]))
        XCTAssertEqual(edge.layer?.backgroundColor, Attention.news.color.cgColor)
        XCTAssertNil(edge.layer?.animation(forKey: "pulse"))
        XCTAssertEqual(row.accessibilityLabel(), "done")
        let chip = try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == " urgent " })
        row.update(model("done", cwd: "/demo/final", waiting: false,
                         labels: [TabLabel(name: "client", color: "Green")]))
        XCTAssertEqual(chip.stringValue, " client ")
        XCTAssertTrue(edge.isHidden)
        row.update(model("done", cwd: "/demo/final", waiting: false))
        XCTAssertNil(chip.superview)
        let bar = try XCTUnwrap(row.subviews.first { $0.layer?.backgroundColor == group.nsColor.cgColor })
        group.color = "Green" // The same mutable group object must invalidate the row's color snapshot.
        row.update(model("done", cwd: "/demo/final", waiting: false))
        XCTAssertEqual(bar.layer?.backgroundColor, group.nsColor.cgColor)
    }

    func testStructuralUpdatesReuseSurvivingRowsAndReleaseClosedWorkspace() throws {
        var closing: Workspace? = Workspace()
        weak var released = closing
        let a = Workspace(); a.customTitle = "a"
        let b = Workspace(); b.customTitle = "b"
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        autoreleasepool { sidebar.update([a, closing!, b], selected: a) }
        let first = try XCTUnwrap(descendants(sidebar).first { $0.accessibilityLabel() == "a" })
        let last = try XCTUnwrap(descendants(sidebar).first { $0.accessibilityLabel() == "b" })
        let width = first.frame.width
        autoreleasepool {
            sidebar.update([b, a], selected: b)
            closing = nil
        }
        autoreleasepool { CATransaction.flush() }
        XCTAssertNil(released)
        // NSStackView's arranged order, not its subview z-order, controls the visible row order.
        let rows = descendants(sidebar).filter { $0 is Row }.sorted {
            sidebar.convert($0.bounds, from: $0).midY > sidebar.convert($1.bounds, from: $1).midY
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0] === last)
        XCTAssertTrue(rows[1] === first)
        XCTAssertEqual(first.frame.width, width, accuracy: 0.01)
        XCTAssertTrue(descendants(last).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "⌘1" })
        let group = TabGroup(name: "API", color: "Blue")
        a.group = group
        sidebar.update([b, a], selected: b)
        XCTAssertTrue(descendants(sidebar).contains { $0 === first })
        group.collapsed = true
        sidebar.update([b, a], selected: b)
        XCTAssertEqual(sidebar.rowHeights.count, 2)
        group.collapsed = false
        sidebar.update([b, a], selected: b)
        XCTAssertEqual(sidebar.rowHeights.count, 3)
        XCTAssertTrue(descendants(sidebar).contains { $0 === last })
    }

    func testGroupMetadataAndCollapseReuseHeaderControls() throws {
        let group = TabGroup(name: "API", color: "Blue", collapsed: true)
        let a = Workspace(); a.group = group
        let b = Workspace(); b.group = group
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        sidebar.update([a], selected: nil)
        let header = try XCTUnwrap(descendants(sidebar).first { $0.accessibilityLabel() == "Group API, 1 tabs, collapsed" })
        let controls = descendants(header)
        for index in 0..<100 {
            group.name = "API \(index)"
            group.color = index.isMultiple(of: 2) ? "Green" : "Blue"
            sidebar.update([a, b], selected: nil)
        }
        XCTAssertTrue(zip(descendants(header), controls).allSatisfy { $0 === $1 })
        XCTAssertEqual(header.accessibilityLabel(), "Group API 99, 2 tabs, collapsed")
        XCTAssertTrue(descendants(header).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "2" && !$0.isHidden })
        group.collapsed = false
        sidebar.update([a, b], selected: nil)
        XCTAssertTrue(descendants(sidebar).contains { $0 === header })
        XCTAssertTrue(zip(descendants(header), controls).allSatisfy { $0 === $1 })
        XCTAssertEqual(header.accessibilityLabel(), "Group API 99, 2 tabs, expanded")
        XCTAssertTrue(descendants(header).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "2" && $0.isHidden })
    }

    func testCollapsedGroupAttentionUpdatesWithoutReplacingControls() throws {
        let group = TabGroup(name: "API", color: "Blue", collapsed: true)
        func model(waiting: Bool = false, unread: Bool = false, working: Bool = false) -> GroupHeader.Model {
            GroupHeader.Model(group: group, count: 2, unread: unread, waiting: waiting, working: working)
        }
        let header = GroupHeader(model(), actions: nil)
        let controls = descendants(header)
        let badge = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == " needs input " })
        XCTAssertTrue(badge.isHidden)
        header.update(model(working: true), actions: nil)
        let dot = try XCTUnwrap(header.subviews.flatMap(descendants).first {
            $0.layer?.backgroundColor == Attention.working.color.cgColor
        })
        XCTAssertFalse(dot.isHidden)
        header.update(model(unread: true, working: true), actions: nil)
        XCTAssertEqual(dot.layer?.backgroundColor, Attention.news.color.cgColor)
        header.update(model(waiting: true, unread: true, working: true), actions: nil)
        XCTAssertFalse(badge.isHidden)
        XCTAssertTrue(dot.isHidden)
        XCTAssertEqual(badge.backgroundColor, Attention.waiting.color)
        group.collapsed = false
        header.update(model(waiting: true), actions: nil)
        XCTAssertTrue(badge.isHidden)
        XCTAssertTrue(dot.isHidden)
        XCTAssertTrue(zip(descendants(header), controls).allSatisfy { $0 === $1 })
    }

    func testTitlebarStatusReusesLabelsAndSeparators() throws {
        let container = ContainerView(sidebar: NSView(), content: NSView())
        container.setInfo(["main", "clean", "ahead 1"])
        let controls = descendants(container)
        for index in 0..<100 { container.setInfo(["branch \(index)", "dirty", "ahead \(index)"]) }
        XCTAssertTrue(zip(descendants(container), controls).allSatisfy { $0 === $1 })
        let labels = descendants(container).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.map(\.stringValue), ["branch 99", "dirty", "ahead 99"])
        container.setInfo(["main"])
        XCTAssertTrue(descendants(container).contains { $0 === labels[0] })
        XCTAssertNil(labels[1].superview)
        XCTAssertNil(labels[2].superview)
        container.setInfo(["main", "clean"])
        XCTAssertTrue(descendants(container).contains { $0 === labels[0] })
        XCTAssertEqual(descendants(container).compactMap { $0 as? NSBox }.count, 1)
        container.setInfo([])
        XCTAssertTrue(descendants(container).compactMap { $0 as? NSTextField }.isEmpty)
        XCTAssertTrue(descendants(container).compactMap { $0 as? NSBox }.isEmpty)
    }
}

extension SidebarTests {
    /// A title update must leave the row clickable without waiting for a layout pass.
    func testRowsTakeClicksRightAfterTitleUpdate() throws {
        let ws = Workspace(); ws.customTitle = "one"
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.update([ws], selected: nil)
        sidebar.layoutSubtreeIfNeeded()
        let p = NSPoint(x: 100, y: sidebar.bounds.height - 60) // inside the first row
        XCTAssertNotNil(sidebar.hitTest(p).flatMap { $0.acceptsFirstMouse(for: nil) ? $0 : nil })
        ws.customTitle = "two" // no layout pass runs before the click
        sidebar.update([ws], selected: nil)
        let hit = try XCTUnwrap(sidebar.hitTest(p))
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "the click fell through to \(type(of: hit))")
    }
}
