import AppKit
import GhosttyKit

/// Tabs, splits, folders and agent sessions, saved so a relaunch can rebuild them.
/// Shells and programs can't survive a quit; Claude Code and Codex sessions are resumed instead.
struct SessionState: Codable, Equatable {
    indirect enum Node: Codable, Equatable {
        case pane(cwd: String?, agent: AgentSession?)
        /// `ratio` is the first child's share of the split.
        case split(vertical: Bool, ratio: Double, first: Node, second: Node)

        var firstPane: (cwd: String?, agent: AgentSession?) {
            switch self {
            case let .pane(cwd, agent): (cwd, agent)
            case let .split(_, _, first, _): first.firstPane
            }
        }
    }

    var tabs: [Node]
    var selected: Int

    static var url: URL {
        // Overridable so test instances never touch the real state.
        if let p = ProcessInfo.processInfo.environment["HELIUM_STATE_FILE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/helium-terminal/state.json")
    }

    static var restoreEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "RestoreSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "RestoreSession") }
    }

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}

extension MainWindowController {
    func captureState() -> SessionState {
        func node(_ v: NSView) -> SessionState.Node? {
            if let p = v as? PaneView { return .pane(cwd: p.surface.pwd, agent: p.agent) }
            guard let s = v as? NSSplitView, s.arrangedSubviews.count == 2,
                  let a = node(s.arrangedSubviews[0]), let b = node(s.arrangedSubviews[1]) else {
                return v.subviews.lazy.compactMap(node).first
            }
            let total = s.isVertical ? s.bounds.width : s.bounds.height
            let first = s.isVertical ? s.arrangedSubviews[0].frame.width : s.arrangedSubviews[0].frame.height
            return .split(vertical: s.isVertical, ratio: total > 0 ? Double(first / total) : 0.5, first: a, second: b)
        }
        let tabs = workspaces.compactMap { node($0.root) }
        let selected = workspaces.firstIndex { $0 === self.selected } ?? 0
        return SessionState(tabs: tabs, selected: selected)
    }

    private static var lastSaved: Data?

    /// Writes the state when it changed. Called from the metadata poll and on quit.
    func saveState() {
        guard let data = try? JSONEncoder().encode(captureState()), data != Self.lastSaved else { return }
        Self.lastSaved = data
        try? FileManager.default.createDirectory(at: SessionState.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: SessionState.url, options: .atomic)
    }

    /// The command typed into an agent pane on relaunch, unless resuming that agent is turned off.
    private static func resumeInput(_ agent: AgentSession?) -> String? {
        guard let agent, AgentSession.resumeEnabled(agent.kind) else { return nil }
        return agent.resumeCommand + "\n"
    }

    /// Rebuilds saved tabs; returns false when there was nothing to restore.
    func restore(_ state: SessionState) -> Bool {
        guard !state.tabs.isEmpty else { return false }
        var ratios: [(NSSplitView, Double)] = []

        func build(_ node: SessionState.Node, in pane: PaneView, _ ws: Workspace) {
            guard case let .split(vertical, ratio, first, second) = node, let app = Ghostty.shared.app else { return }
            let leaf = second.firstPane
            let new = PaneView(surface: SurfaceView(app: app, workingDirectory: leaf.agent?.cwd ?? leaf.cwd,
                                                    initialInput: Self.resumeInput(leaf.agent)))
            ws.split(pane, with: new, vertical ? GHOSTTY_SPLIT_DIRECTION_RIGHT : GHOSTTY_SPLIT_DIRECTION_DOWN)
            if let split = new.superview as? NSSplitView { ratios.append((split, ratio)) }
            build(first, in: pane, ws)
            build(second, in: new, ws)
        }

        for tab in state.tabs {
            let leaf = tab.firstPane
            guard let ws = newWorkspace(cwd: leaf.agent?.cwd ?? leaf.cwd, initialInput: Self.resumeInput(leaf.agent)),
                  let pane = ws.panes.first else { continue }
            build(tab, in: pane, ws)
        }
        if workspaces.indices.contains(state.selected) { select(workspaces[state.selected]) }
        // Split positions need real sizes, which exist only after the window lays out.
        DispatchQueue.main.async {
            for (split, ratio) in ratios {
                split.superview?.layoutSubtreeIfNeeded()
                let total = split.isVertical ? split.bounds.width : split.bounds.height
                split.setPosition(total * ratio, ofDividerAt: 0)
            }
        }
        return !workspaces.isEmpty
    }
}
