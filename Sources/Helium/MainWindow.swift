import AppKit
import GhosttyKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private(set) var workspaces: [Workspace] = []
    private(set) var selected: Workspace?
    private let sidebar = SidebarView()
    private let content = NSView()
    private var pollTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 500, height: 300)
        window.setFrameAutosaveName("HeliumMain")
        if !window.setFrameUsingName("HeliumMain") { window.center() }
        super.init(window: window)
        window.delegate = self

        let container = ContainerView(sidebar: sidebar, content: content)
        window.contentView = container
        sidebar.onSelect = { [weak self] ws in self?.select(ws) }
        sidebar.actions = self

        // Branch and port metadata changes outside the terminal, so poll it.
        // Only the cheap file and libproc reads in Metadata run here; no subprocesses.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshMetadata()
        }
        pollTimer?.tolerance = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Workspaces

    @discardableResult
    func newWorkspace(inheriting from: SurfaceView? = nil, cwd: String? = nil, command: String? = nil,
                      initialInput: String? = nil) -> Workspace? {
        guard let app = Ghostty.shared.app else { return nil }
        let dir = cwd ?? from?.inheritedWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let ws = Workspace()
        ws.onChange = { [weak self] in self?.metadataChanged() }
        ws.root.frame = content.bounds
        ws.setFirst(PaneView(surface: SurfaceView(app: app, workingDirectory: dir, command: command,
                                                  initialInput: initialInput)))
        content.addSubview(ws.root)
        workspaces.append(ws)
        select(ws)
        refreshMetadata()
        return ws
    }

    func select(_ ws: Workspace) {
        // UI callbacks (a rename ending, a stale menu) can name a tab that has since closed.
        guard workspaces.contains(where: { $0 === ws }) else { return }
        ws.group?.collapsed = false // like Chrome, activating a tab opens its group
        selected = ws
        for w in workspaces { w.root.isHidden = w !== ws }
        updateVisibility()
        if let pane = ws.focusedPane { window?.makeFirstResponder(pane.surface) }
        metadataChanged()
        refreshGitStatus()
    }

    func gotoWorkspace(_ n: Int) {
        guard let cur = selected, let i = workspaces.firstIndex(where: { $0 === cur }) else { return }
        let target: Int = switch Int32(n) {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: (i - 1 + workspaces.count) % workspaces.count
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: (i + 1) % workspaces.count
        case GHOSTTY_GOTO_TAB_LAST.rawValue: workspaces.count - 1
        default: min(n - 1, workspaces.count - 1) // goto_tab:N is 1-based
        }
        if target >= 0 { select(workspaces[target]) }
    }

    func closeWorkspace(containing view: SurfaceView) {
        guard let ws = view.pane?.workspace else { return }
        if ws.panes.contains(where: { $0.surface.needsConfirmQuit }),
           !confirm("Close this tab?", "A process is still running in it.") { return }
        guard confirmDeletingGroup(closing: ws) else { return }
        ws.panes.forEach { close($0) }
    }

    // MARK: Panes

    func split(_ view: SurfaceView, _ dir: ghostty_action_split_direction_e) {
        guard let app = Ghostty.shared.app, let pane = view.pane, let ws = pane.workspace else { return }
        let new = PaneView(surface: SurfaceView(app: app, workingDirectory: view.inheritedWorkingDirectory))
        ws.split(pane, with: new, dir)
        // A split made in a background tab (from the socket) mustn't take the keyboard from the visible one.
        if ws === selected { window?.makeFirstResponder(new.surface) } else { ws.focused = new }
        updateVisibility()
    }

    func gotoSplit(from view: SurfaceView, _ dir: ghostty_action_goto_split_e) {
        guard let pane = view.pane, let next = pane.workspace?.neighbor(of: pane, dir) else { return }
        window?.makeFirstResponder(next.surface)
    }

    func equalize(containing view: SurfaceView) {
        view.pane?.workspace?.equalizeAll()
    }

    /// libghostty asks to close a surface (shell exited, or cmd+w).
    func requestClose(_ view: SurfaceView, processAlive: Bool) {
        guard let pane = view.pane else { return }
        if processAlive, !confirm("Close this pane?", "A process is still running in it.") { return }
        // Closing the last pane closes the tab; ask about its group only when the user closed it.
        if let ws = pane.workspace, ws.panes.count == 1, !view.processExited,
           !confirmDeletingGroup(closing: ws) { return }
        close(pane)
    }

    private func close(_ pane: PaneView) {
        guard let ws = pane.workspace else { return }
        let siblings = ws.panes
        let i = siblings.firstIndex(of: pane) ?? 0
        ws.remove(pane)
        pane.surface.destroy()

        let remaining = ws.panes
        if remaining.isEmpty {
            ws.root.removeFromSuperview()
            let wi = workspaces.firstIndex { $0 === ws } ?? 0
            workspaces.removeAll { $0 === ws }
            if workspaces.isEmpty {
                window?.close()
                return
            }
            if selected === ws { select(workspaces[min(wi, workspaces.count - 1)]) }
        } else {
            if ws.focused === pane || ws.focused == nil { ws.focused = remaining[min(i, remaining.count - 1)] }
            if ws === selected, let f = ws.focused { window?.makeFirstResponder(f.surface) }
        }
        metadataChanged()
    }

    // MARK: Tab groups

    /// Groups in sidebar order.
    var groups: [TabGroup] {
        var seen = Set<String>()
        return workspaces.compactMap(\.group).filter { seen.insert($0.id).inserted }
    }

    /// Chrome's "Close Tab and Delete Group?" when `ws` is the last tab of its group. True means go ahead.
    private func confirmDeletingGroup(closing ws: Workspace) -> Bool {
        guard let g = ws.group, !workspaces.contains(where: { $0 !== ws && $0.group === g }),
              UserDefaults.standard.object(forKey: "AskBeforeDeletingGroup") as? Bool ?? true else { return true }
        let alert = NSAlert()
        alert.messageText = "Close Tab and Delete Group?"
        alert.informativeText = g.name.isEmpty ? "This is the last tab in the group." : "This is the last tab in “\(g.name)”."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't Ask Again"
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: "AskBeforeDeletingGroup")
        }
        return ok
    }

    /// Keeps each group's tabs together, at the position of the group's first tab.
    private func regroup() {
        var out: [Workspace] = []
        var emitted = Set<String>()
        for ws in workspaces {
            guard let g = ws.group else { out.append(ws); continue }
            if emitted.insert(g.id).inserted { out += workspaces.filter { $0.group === g } }
        }
        workspaces = out
        metadataChanged()
        saveState()
    }

    /// Moves `ws` to the end of `group`.
    private func move(_ ws: Workspace, into group: TabGroup) {
        guard let old = workspaces.firstIndex(where: { $0 === ws }) else { return }
        workspaces.remove(at: old)
        ws.group = group
        let last = workspaces.lastIndex { $0.group === group }
        workspaces.insert(ws, at: last.map { $0 + 1 } ?? old) // a new group starts where the tab was
        if ws === selected { group.collapsed = false } // never hide the selected tab
        regroup()
    }

    func pane(id: Int) -> PaneView? {
        workspaces.lazy.flatMap(\.panes).first { $0.surface.id == id }
    }

    // MARK: Notifications

    /// Called for OSC 9/777 desktop notifications, the bell, and `helium notify`.
    func notify(_ view: SurfaceView, text: String?) {
        guard let pane = view.pane, let ws = pane.workspace else { return }
        let looking = NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === view
        if let text, Workspace.isWaitingForInput(text) {
            if !looking { pane.waiting = true }
        } else {
            if let text, Workspace.isIdleReminder(text) {
                ws.notification = "Done, waiting for you"
            } else if let text, !text.isEmpty {
                ws.notification = text
            }
            if !looking { pane.ringing = true }
        }
        metadataChanged()
    }

    // MARK: Metadata

    func metadataChanged() {
        sidebar.update(workspaces, selected: selected)
        (window?.contentView as? ContainerView)?.setInfo(
            selected.flatMap { ws in ws.branch.map { Metadata.branchParts($0, ws.gitStatus) } } ?? [])
        window?.title = selected?.title ?? "Helium"
    }

    private let gitQueue = DispatchQueue(label: "helium.git")
    private var gitRunning = false

    /// Runs git for the selected tab only, and only while the window can be seen.
    func refreshGitStatus() {
        guard !gitRunning, let ws = selected, ws.branch != nil, let dir = ws.cwd,
              window?.occlusionState.contains(.visible) == true else { return }
        gitRunning = true
        gitQueue.async {
            let st = Metadata.gitStatus(dir)
            DispatchQueue.main.async { [weak self] in
                self?.gitRunning = false
                guard ws.cwd == dir, ws.gitStatus != st else { return }
                ws.gitStatus = st
                self?.metadataChanged()
            }
        }
    }

    func refreshMetadata() {
        let tree = ProcessTree()
        for ws in workspaces {
            let branch = ws.cwd.flatMap(Metadata.gitBranch)
            if branch != ws.branch { ws.gitStatus = nil } // another branch or repo; the next git run fills it in
            ws.branch = branch
            ws.ports = Metadata.listeningPorts(ttys: ws.panes.compactMap(\.surface.ttyName), tree: tree)
            // Fall back to the foreground process's cwd when shell integration isn't reporting it.
            for p in ws.panes where p.surface.pwd == nil {
                p.surface.pwd = Metadata.cwd(of: p.surface.foregroundPID)
            }
        }
        refreshAgents(tree)
        refreshGitStatus()
        metadataChanged()
        saveState()
    }

    /// Notes which panes run Claude Code or Codex, so a relaunch can resume them.
    func refreshAgents(_ tree: ProcessTree = ProcessTree()) {
        for p in workspaces.flatMap(\.panes) {
            p.agent = p.surface.ttyName.flatMap(Metadata.ttyDevice).flatMap { Agents.session(onTTY: $0, tree: tree) }
        }
    }

    // MARK: Window

    /// Hidden tabs and a hidden window (minimized, covered, other Space) stop
    /// rendering; libghostty also frees their GPU buffers.
    private func updateVisibility() {
        // Before the first show occlusionState reads "not visible" and no change
        // notification follows, so only trust it once the window has been on screen.
        // (Not isVisible: a minimized or hidden window is also not "visible" but must stop rendering.)
        let windowVisible = !shown || window?.occlusionState.contains(.visible) != false
        for w in workspaces {
            let visible = windowVisible && w === selected
            w.panes.forEach { $0.surface.setVisible(visible) }
        }
    }

    private var shown = false

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window?.occlusionState.contains(.visible) == true { shown = true }
        updateVisibility()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspaces.flatMap(\.panes).forEach { $0.surface.syncFocus() }
        if let pane = selected?.focusedPane, window?.firstResponder === pane.surface {
            pane.ringing = false
            metadataChanged()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        workspaces.flatMap(\.panes).forEach { $0.surface.syncFocus() }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        for ws in workspaces { ws.panes.forEach { $0.surface.destroy() } }
        workspaces.removeAll()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = workspaces.flatMap(\.panes).contains { $0.surface.needsConfirmQuit }
        return !busy || confirm("Close the window?", "Processes are still running.")
    }

    private func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Lays out the fixed-width sidebar and the terminal area.
private final class ContainerView: NSView {
    let sidebar: NSView
    let content: NSView
    private let handle = ResizeHandle()
    /// The selected tab's git branch and status, in the titlebar strip above the terminal.
    private let info = NSStackView()
    private var infoParts: [String] = []

    /// Labels with native separators between them; rebuilt only when the text changes.
    func setInfo(_ parts: [String]) {
        guard parts != infoParts else { return }
        infoParts = parts
        info.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, text) in parts.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 14).isActive = true
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true // narrow, so it draws vertically
                info.addArrangedSubview(line)
            }
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            info.addArrangedSubview(l)
        }
        needsLayout = true
    }

    /// Sidebar width, dragged by the user and remembered across launches.
    private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "SidebarWidth")
        return saved > 0 ? saved : 240
    }()

    init(sidebar: NSView, content: NSView) {
        self.sidebar = sidebar
        self.content = content
        super.init(frame: .zero)
        addSubview(sidebar)
        addSubview(content)
        addSubview(handle)
        info.spacing = 12
        info.alignment = .centerY
        addSubview(info)
        handle.onDrag = { [weak self] x in self?.resizeSidebar(to: x) }
        NotificationCenter.default.addObserver(forName: .heliumSidebarWidthChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.resizeSidebar(to: UserDefaults.standard.double(forKey: "SidebarWidth"))
        }
        handle.onDragEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.sidebarWidth), forKey: "SidebarWidth")
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func resizeSidebar(to x: CGFloat) {
        // Keep the sidebar readable and leave the terminal at least 300 pt.
        sidebarWidth = min(max(x, 160), max(160, min(520, bounds.width - 300)))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Re-clamp here too: shrinking the window must not push the terminal below 300 pt (or negative).
        let w = min(sidebarWidth, max(160, bounds.width - 300))
        sidebar.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        handle.frame = NSRect(x: w - 3, y: 0, width: 6, height: bounds.height)
        // Leave room for the transparent titlebar above the terminal.
        let top = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 28
        content.frame = NSRect(x: w, y: 0, width: bounds.width - w, height: bounds.height - top)
        let h = info.fittingSize.height
        let width = min(info.fittingSize.width, max(0, bounds.width - w - 24)) // left-aligned, cut off at the right
        info.frame = NSRect(x: w + 12, y: bounds.height - top + (top - h) / 2, width: width, height: h)
    }
}

/// Invisible strip on the sidebar's edge that resizes it.
private final class ResizeHandle: NSView {
    /// Called with the mouse's x in the superview while dragging.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

extension MainWindowController: TabGroupActions {
    func addToNewGroup(_ ws: Workspace) {
        // Like Chrome, a new group takes the first color not already in use.
        let used = Set(groups.map(\.color))
        let g = TabGroup(color: TabGroup.colors.first { !used.contains($0.name) }?.name ?? "Blue")
        move(ws, into: g)
        sidebar.editGroup(g)
    }

    func add(_ ws: Workspace, to group: TabGroup) { move(ws, into: group) }

    func removeFromGroup(_ ws: Workspace) {
        guard let g = ws.group, let old = workspaces.firstIndex(where: { $0 === ws }) else { return }
        // Leave the group to sit right after it (an emptied group simply disappears).
        workspaces.remove(at: old)
        ws.group = nil
        let last = workspaces.lastIndex { $0.group === g }
        workspaces.insert(ws, at: last.map { $0 + 1 } ?? old)
        regroup()
    }

    func toggleCollapsed(_ group: TabGroup) {
        group.collapsed.toggle()
        // Chrome moves off a tab that disappears into a collapsed group.
        if group.collapsed, let sel = selected, sel.group === group {
            // With nowhere visible to go, stay expanded rather than hide the selected tab.
            guard let other = workspaces.first(where: { $0.group?.collapsed != true }) else {
                group.collapsed = false
                return
            }
            selected = nil
            select(other)
            group.collapsed = true
        }
        metadataChanged()
        saveState()
    }

    func ungroup(_ group: TabGroup) {
        for ws in workspaces where ws.group === group { ws.group = nil }
        regroup()
    }

    func closeGroup(_ group: TabGroup) {
        let members = workspaces.filter { $0.group === group }
        if members.flatMap(\.panes).contains(where: { $0.surface.needsConfirmQuit }),
           !confirm("Close this group?", "Processes are still running in its tabs.") { return }
        members.flatMap(\.panes).forEach { close($0) }
    }

    func newTab(in group: TabGroup) {
        guard let ws = newWorkspace(inheriting: selected?.focusedPane?.surface) else { return }
        move(ws, into: group)
        select(ws)
    }

    /// A sidebar drag: puts `ws` in front of `before` (nil: at the end) and into `group`.
    func move(_ ws: Workspace, before: Workspace?, group: TabGroup?) {
        guard let old = workspaces.firstIndex(where: { $0 === ws }) else { return }
        workspaces.remove(at: old)
        ws.group = group
        let at = before === ws ? old : before.flatMap { b in workspaces.firstIndex { $0 === b } } ?? workspaces.count
        workspaces.insert(ws, at: at)
        regroup()
    }

    func groupsChanged() {
        metadataChanged()
        saveState() // a group's name or color
    }
}
