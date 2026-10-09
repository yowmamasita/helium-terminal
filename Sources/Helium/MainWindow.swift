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
        sidebar.onNew = { [weak self] in self?.newWorkspace(inheriting: self?.selected?.focusedPane?.surface) }

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
    func newWorkspace(inheriting from: SurfaceView? = nil, cwd: String? = nil, command: String? = nil) -> Workspace? {
        guard let app = Ghostty.shared.app else { return nil }
        let dir = cwd ?? from?.inheritedWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let ws = Workspace()
        ws.onChange = { [weak self] in self?.metadataChanged() }
        ws.root.frame = content.bounds
        ws.setFirst(PaneView(surface: SurfaceView(app: app, workingDirectory: dir, command: command)))
        content.addSubview(ws.root)
        workspaces.append(ws)
        select(ws)
        refreshMetadata()
        return ws
    }

    func select(_ ws: Workspace) {
        selected = ws
        for w in workspaces { w.root.isHidden = w !== ws }
        updateVisibility()
        if let pane = ws.focusedPane { window?.makeFirstResponder(pane.surface) }
        metadataChanged()
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
        ws.panes.forEach { close($0) }
    }

    // MARK: Panes

    func split(_ view: SurfaceView, _ dir: ghostty_action_split_direction_e) {
        guard let app = Ghostty.shared.app, let pane = view.pane, let ws = pane.workspace else { return }
        let new = PaneView(surface: SurfaceView(app: app, workingDirectory: view.inheritedWorkingDirectory))
        ws.split(pane, with: new, dir)
        window?.makeFirstResponder(new.surface)
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

    func pane(id: Int) -> PaneView? {
        workspaces.lazy.flatMap(\.panes).first { $0.surface.id == id }
    }

    // MARK: Notifications

    /// Called for OSC 9/777 desktop notifications, the bell, and `helium notify`.
    func notify(_ view: SurfaceView, text: String?) {
        guard let pane = view.pane, let ws = pane.workspace else { return }
        if let text, !text.isEmpty { ws.notification = text }
        let looking = NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === view
        if !looking { pane.ringing = true }
        metadataChanged()
    }

    // MARK: Metadata

    func metadataChanged() {
        sidebar.update(workspaces, selected: selected)
        window?.title = selected?.title ?? "Helium"
    }

    private func refreshMetadata() {
        let tree = ProcessTree()
        for ws in workspaces {
            ws.branch = ws.cwd.flatMap(Metadata.gitBranch)
            ws.ports = Metadata.listeningPorts(ttys: ws.panes.compactMap(\.surface.ttyName), tree: tree)
            // Fall back to the foreground process's cwd when shell integration isn't reporting it.
            for p in ws.panes where p.surface.pwd == nil {
                p.surface.pwd = Metadata.cwd(of: p.surface.foregroundPID)
            }
        }
        metadataChanged()
    }

    // MARK: Window

    /// Hidden tabs and a hidden window (minimized, covered, other Space) stop
    /// rendering; libghostty also frees their GPU buffers.
    private func updateVisibility() {
        // Before the first show occlusionState reads "not visible" and no change
        // notification follows, so only trust it once the window is on screen.
        let windowVisible = window.map { !$0.isVisible || $0.occlusionState.contains(.visible) } ?? true
        for w in workspaces {
            let visible = windowVisible && w === selected
            w.panes.forEach { $0.surface.setVisible(visible) }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
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
        let w = sidebarWidth
        sidebar.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        handle.frame = NSRect(x: w - 3, y: 0, width: 6, height: bounds.height)
        // Leave room for the transparent titlebar above the terminal.
        let top = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 28
        content.frame = NSRect(x: w, y: 0, width: bounds.width - w, height: bounds.height - top)
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
