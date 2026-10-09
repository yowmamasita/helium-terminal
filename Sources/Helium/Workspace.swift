import AppKit
import GhosttyKit

/// Wraps a surface with the notification ring. libghostty owns the surface's
/// layer, so the ring is a separate view drawn on top.
final class PaneView: NSView {
    let surface: SurfaceView
    weak var workspace: Workspace?
    private let ring = RingView()
    private let linkPreview = NSTextField(labelWithString: "")

    /// The Claude Code or Codex session running here, refreshed by the metadata poll.
    var agent: AgentSession?

    /// Something new happened here (notification or bell); cleared by focusing the pane.
    var ringing = false {
        didSet { updateRing() }
    }

    /// An agent here is blocked on the user; cleared only by typing into the pane.
    var waiting = false {
        didSet { updateRing() }
    }

    private func updateRing() {
        ring.isHidden = !ringing && !waiting
        ring.layer?.borderColor = (waiting ? NSColor.systemOrange : NSColor.systemBlue).cgColor
    }

    func userTyped() {
        guard waiting else { return }
        waiting = false
        workspace?.onChange?()
    }

    /// The URL under the mouse (libghostty reports it while a link is hovered with cmd held).
    var hoveredLink: String? {
        didSet {
            linkPreview.stringValue = hoveredLink ?? ""
            linkPreview.isHidden = hoveredLink == nil
            layoutLinkPreview()
        }
    }

    init(surface: SurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        surface.pane = self
        surface.autoresizingMask = [.width, .height]
        ring.autoresizingMask = [.width, .height]
        ring.isHidden = true
        addSubview(surface)
        addSubview(ring)

        linkPreview.font = .systemFont(ofSize: 11)
        linkPreview.textColor = .labelColor
        linkPreview.lineBreakMode = .byTruncatingMiddle
        linkPreview.drawsBackground = true
        linkPreview.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        linkPreview.wantsLayer = true
        linkPreview.layer?.cornerRadius = 4
        linkPreview.isHidden = true
        addSubview(linkPreview)
    }

    private func layoutLinkPreview() {
        guard hoveredLink != nil else { return }
        let size = linkPreview.intrinsicContentSize
        let width = min(size.width + 12, bounds.width - 12)
        linkPreview.frame = NSRect(x: 6, y: 6, width: max(width, 0), height: size.height + 4)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        surface.frame = bounds
        ring.frame = bounds
        layoutLinkPreview()
    }

    func focusChanged(_ surface: SurfaceView) {
        ringing = false
        workspace?.focused = self
        workspace?.onChange?()
    }
}

private final class RingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.systemBlue.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A sidebar tab: a tree of panes built from nested NSSplitViews.
final class Workspace {
    private static var nextID = 1

    let id: Int
    let root = NSView()
    weak var focused: PaneView?
    var notification: String?
    var branch: String?
    var ports: [Int] = []
    var onChange: (() -> Void)?

    init() {
        id = Self.nextID
        Self.nextID += 1
        root.autoresizingMask = [.width, .height]
    }

    /// Panes in reading order (depth-first through the split tree).
    var panes: [PaneView] {
        func walk(_ v: NSView) -> [PaneView] {
            if let p = v as? PaneView { return [p] }
            return v.subviews.flatMap(walk)
        }
        return walk(root)
    }

    var focusedPane: PaneView? { focused ?? panes.first }
    var unread: Bool { panes.contains { $0.ringing } }
    var waiting: Bool { panes.contains { $0.waiting } }

    /// Agent notifications that mean "blocked until you answer" (Claude Code, Codex and similar),
    /// shown as a badge rather than as message text.
    static func isWaitingForInput(_ text: String) -> Bool {
        let t = text.lowercased()
        if isIdleReminder(text) { return false }
        return ["needs your input", "needs input", "awaiting input",
                "needs your permission", "needs your approval", "waiting for approval", "waiting for your approval",
                "requires approval", "waiting for your response",
                // Codex: "Approval requested: <command>", "Codex wants to edit <file>"
                "approval requested", "wants to edit", "wants to run"].contains { t.contains($0) }
    }

    /// Claude Code's "Claude is waiting for your input", sent about 60 s after a turn ends.
    /// It means the turn is done, not that the agent is blocked.
    static func isIdleReminder(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("waiting for your input") || t.contains("waiting for input")
    }

    /// Set by double-clicking the tab; nil means the automatic title.
    var customTitle: String?
    /// Names of Gmail-style labels (see LabelStore).
    var labels: [String] = []
    /// Chrome-style tab group; a group's tabs are kept next to each other.
    var group: TabGroup?

    var title: String {
        if let customTitle { return customTitle }
        guard let s = focusedPane?.surface else { return "Terminal" }
        if !s.title.isEmpty { return s.title }
        return s.pwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
    }

    var cwd: String? { focusedPane?.surface.pwd }

    func setFirst(_ pane: PaneView) {
        pane.workspace = self
        pane.frame = root.bounds
        pane.autoresizingMask = [.width, .height]
        root.addSubview(pane)
        focused = pane
    }

    /// Replaces `pane` with a split holding `pane` and `new`.
    func split(_ pane: PaneView, with new: PaneView, _ dir: ghostty_action_split_direction_e) {
        guard let parent = pane.superview else { return }
        new.workspace = self
        let split = NSSplitView(frame: pane.frame)
        split.isVertical = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT || dir == GHOSTTY_SPLIT_DIRECTION_LEFT
        split.dividerStyle = .thin
        split.autoresizingMask = pane.autoresizingMask

        if let ps = parent as? NSSplitView, let i = ps.subviews.firstIndex(of: pane) {
            ps.insertArrangedSubview(split, at: i)
            ps.removeArrangedSubview(pane)
            pane.removeFromSuperview()
        } else {
            pane.removeFromSuperview()
            parent.addSubview(split)
        }
        let after = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT || dir == GHOSTTY_SPLIT_DIRECTION_DOWN
        split.addArrangedSubview(after ? pane : new)
        split.addArrangedSubview(after ? new : pane)
        split.adjustSubviews()
        Self.equalize(split)
    }

    /// Removes `pane`, collapsing its split into the remaining sibling.
    func remove(_ pane: PaneView) {
        guard let split = pane.superview as? NSSplitView else {
            pane.removeFromSuperview()
            return
        }
        split.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        guard split.arrangedSubviews.count == 1, let survivor = split.arrangedSubviews.first,
              let parent = split.superview else { return }
        split.removeArrangedSubview(survivor)
        survivor.removeFromSuperview()
        survivor.frame = split.frame
        survivor.autoresizingMask = split.autoresizingMask
        if let ps = parent as? NSSplitView, let i = ps.subviews.firstIndex(of: split) {
            ps.insertArrangedSubview(survivor, at: i)
            ps.removeArrangedSubview(split)
            split.removeFromSuperview()
        } else {
            split.removeFromSuperview()
            parent.addSubview(survivor)
        }
    }

    func equalizeAll() {
        func walk(_ v: NSView) {
            if let s = v as? NSSplitView { Self.equalize(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
    }

    private static func equalize(_ split: NSSplitView) {
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let each = (total - split.dividerThickness * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<(n - 1) {
            split.setPosition(each * CGFloat(i + 1) + split.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    /// The pane next to `from` in `dir`, by on-screen geometry.
    func neighbor(of from: PaneView, _ dir: ghostty_action_goto_split_e) -> PaneView? {
        let all = panes
        guard let i = all.firstIndex(of: from) else { return nil }
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return all[(i - 1 + all.count) % all.count]
        case GHOSTTY_GOTO_SPLIT_NEXT: return all[(i + 1) % all.count]
        default: break
        }
        let f = from.convert(from.bounds, to: root)
        let candidates = all.filter { $0 !== from }.map { ($0, $0.convert($0.bounds, to: root)) }.filter { _, r in
            // root is not flipped: larger y is higher on screen.
            switch dir {
            case GHOSTTY_GOTO_SPLIT_LEFT: return r.maxX <= f.minX + 1
            case GHOSTTY_GOTO_SPLIT_RIGHT: return r.minX >= f.maxX - 1
            case GHOSTTY_GOTO_SPLIT_UP: return r.minY >= f.maxY - 1
            case GHOSTTY_GOTO_SPLIT_DOWN: return r.maxY <= f.minY + 1
            default: return false
            }
        }
        return candidates.min { a, b in
            hypot(a.1.midX - f.midX, a.1.midY - f.midY) < hypot(b.1.midX - f.midX, b.1.midY - f.midY)
        }?.0
    }
}
