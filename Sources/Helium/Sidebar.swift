import AppKit

/// Vertical tab list: title, cwd, ports and the latest notification per workspace.
final class SidebarView: NSVisualEffectView, NSPopoverDelegate {
    var onSelect: ((Workspace) -> Void)?

    private let stack = NSStackView()
    // Two separate freezes, so one ending can't unfreeze the other.
    private var renaming = false
    private var popoverOpen = false
    private var dragging = false
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        addSubview(scroll)

        update.bezelStyle = .accessoryBarAction
        update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update ready")
        update.imagePosition = .imageLeading
        update.contentTintColor = .systemBlue
        update.target = self
        update.action = #selector(relaunchToUpdate)
        update.isHidden = true
        update.translatesAutoresizingMaskIntoConstraints = false
        addSubview(update)
        NSLayoutConstraint.activate([
            update.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            update.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            update.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        // The tab list runs to the bottom unless the update button needs the space.
        listToBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        listAboveUpdate = scroll.bottomAnchor.constraint(equalTo: update.topAnchor, constant: -6)
        listToBottom.isActive = true
        NotificationCenter.default.addObserver(forName: .heliumUpdaterChanged, object: nil, queue: .main) {
            [weak self] _ in self?.updaterChanged()
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildColors() }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    /// Heights of the tab rows, top to bottom (for tests).
    var rowHeights: [CGFloat] { stack.arrangedSubviews.map(\.frame.height) }

    private let update = NSButton(title: "", target: nil, action: nil)
    private var listToBottom: NSLayoutConstraint!
    private var listAboveUpdate: NSLayoutConstraint!

    private func updaterChanged() {
        let version: String? = if case .ready(let v) = Updater.shared.state { v } else { nil }
        update.isHidden = version == nil
        listToBottom.isActive = version == nil
        listAboveUpdate.isActive = version != nil
        guard let version else { return }
        update.title = "Relaunch for \(version)"
        update.toolTip = "Helium \(version) is installed. Relaunch to start it; open terminals will close."
    }

    @objc private func relaunchToUpdate() { Updater.shared.relaunch() }

    func update(_ workspaces: [Workspace], selected: Workspace?) {
        // Keep the field editor, popover anchor and lifted row intact until their interaction ends.
        guard !renaming, !popoverOpen, !dragging else { return }
        let models = workspaces.enumerated().map { index, ws in
            Row.Model(ws: ws, index: index + 1, title: ws.title, cwd: ws.cwd.map(Self.abbreviate),
                ports: ws.ports, notification: ws.notification, unread: ws.unread, waiting: ws.waiting,
                working: ws.working, selected: ws === selected,
                labels: ws.labels.compactMap(LabelStore.label(named:)), group: ws.group)
        }
        var summaries: [String: GroupHeader.Model] = [:]
        for model in models {
            guard let group = model.group else { continue }
            let previous = summaries[group.id]
            summaries[group.id] = GroupHeader.Model(group: group, count: (previous?.count ?? 0) + 1,
                unread: (previous?.unread ?? false) || model.unread,
                waiting: (previous?.waiting ?? false) || model.waiting,
                working: (previous?.working ?? false) || model.working)
        }
        var items: [Item] = []
        var views: [NSView] = []
        var liveRows = Set<ObjectIdentifier>()
        var liveHeaders = Set<String>()
        var lastGroup: TabGroup?
        for model in models {
            let ws = model.ws
            if let group = ws.group, group !== lastGroup, let model = summaries[group.id] {
                let header = headers[group.id] ?? GroupHeader(model, actions: actions)
                header.sidebar = self
                header.update(model, actions: actions)
                headers[group.id] = header
                liveHeaders.insert(group.id)
                items.append(.header(group, first: ws))
                views.append(header)
            }
            lastGroup = ws.group
            if ws.group?.collapsed == true { continue }
            let key = ObjectIdentifier(ws)
            let row: Row
            if let existing = rowViews[key] {
                row = existing
                row.update(model)
            } else {
                row = Row(model) { [weak self, weak ws] in
                    if let ws { self?.onSelect?(ws) }
                }
                row.onEditing = { [weak self, weak ws] on in
                    self?.renaming = on
                    // Another field may be taking focus as editing ends.
                    if !on { DispatchQueue.main.async { ws?.onChange?() } }
                }
                rowViews[key] = row
            }
            row.actions = actions
            row.sidebar = self
            liveRows.insert(key)
            items.append(.row(ws))
            views.append(row)
        }
        kinds = items
        if rowViews.count != liveRows.count { rowViews = rowViews.filter { liveRows.contains($0.key) } }
        if headers.count != liveHeaders.count { headers = headers.filter { liveHeaders.contains($0.key) } }
        let current = stack.arrangedSubviews
        if current.count != views.count || zip(current, views).contains(where: { $0 !== $1 }) {
            let liveViews = Set(views.map(ObjectIdentifier.init))
            for view in current where !liveViews.contains(ObjectIdentifier(view)) {
                view.removeFromSuperview()
            }
            widths = widths.filter { liveViews.contains($0.key) }
            for (index, view) in views.enumerated() {
                let key = ObjectIdentifier(view)
                if view.superview !== stack {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    stack.insertArrangedSubview(view, at: index)
                    let width = widths[key] ?? view.widthAnchor.constraint(equalTo: stack.widthAnchor)
                    widths[key] = width
                    width.isActive = true
                } else if stack.arrangedSubviews[index] !== view {
                    // Removing just the arranged membership preserves the view and its width constraint.
                    stack.removeArrangedSubview(view)
                    stack.insertArrangedSubview(view, at: index)
                }
            }
            // A click queued behind a structural change must already have a target.
            layoutSubtreeIfNeeded()
        }
    }

    weak var actions: TabGroupActions?
    private var kinds: [Item] = []
    private var headers: [String: GroupHeader] = [:]
    private var rowViews: [ObjectIdentifier: Row] = [:]
    private var widths: [ObjectIdentifier: NSLayoutConstraint] = [:]

    /// Starts renaming on the current row, even if a structural change replaced the menu's original row.
    func rename(_ ws: Workspace) {
        rowViews[ObjectIdentifier(ws)]?.beginEditing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildColors()
    }

    /// Resolve layer-backed colors again without replacing controls.
    func rebuildColors() {
        rowViews.values.forEach { $0.refreshColors() }
        headers.values.forEach { $0.refresh() }
    }

    /// Opens the "Name this group" popover on a group's header; the sidebar holds still while it's open.
    func editGroup(_ group: TabGroup) {
        guard !popoverOpen, let header = headers[group.id], let window = header.window else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GroupEditor(group: group) { [weak header] in header?.refresh() }
        popover.delegate = self
        window.layoutIfNeeded() // a header added this turn has no size yet to anchor to
        popover.show(relativeTo: header.bounds, of: header, preferredEdge: .maxX)
        // Freeze only once it's up: a popover that never shows never closes, and the sidebar would stay frozen.
        popoverOpen = popover.isShown
    }

    func popoverDidClose(_ notification: Notification) {
        popoverOpen = false
        actions?.groupsChanged()
    }

    // MARK: Drag to reorder

    /// What a view in the stack shows; a header carries its group's first tab, to drop in front of.
    enum Item {
        case header(TabGroup, first: Workspace)
        case row(Workspace)
    }

    /// Drags `ws`'s row like an iTerm2 tab: the row lifts and follows the pointer while the others slide apart to
    /// open a gap where it will land. Periodic tracking events keep autoscroll moving even on a still pointer.
    func trackDrag(_ ws: Workspace, from down: NSEvent) {
        guard let window, let doc = stack.superview else { return }
        let start = down.locationInWindow
        var lifted: (row: NSView, gap: NSView, grab: CGFloat)?
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05) // keeps autoscroll going on a still pointer
        defer { NSEvent.stopPeriodicEvents() }
        var last = down
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .periodic], timeout: .infinity,
                           mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type != .periodic { last = event }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            if lifted == nil {
                // A few points of slack so a shaky click doesn't count as a drag.
                guard hypot(last.locationInWindow.x - start.x, last.locationInWindow.y - start.y) > 4,
                      let row = rowViews[ObjectIdentifier(ws)], let i = stack.arrangedSubviews.firstIndex(of: row)
                else { return }
                dragging = true
                let frame = doc.convert(row.frame, from: stack)
                let gap = NSView()
                gap.heightAnchor.constraint(equalToConstant: frame.height).isActive = true
                stack.insertArrangedSubview(gap, at: i)
                gap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                doc.addSubview(row) // out of the stack, on top of it
                row.translatesAutoresizingMaskIntoConstraints = true
                row.frame = frame
                row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
                row.shadow = NSShadow()
                row.layer?.shadowOpacity = 0.3
                row.layer?.shadowRadius = 6
                row.layer?.shadowOffset = CGSize(width: 0, height: -2)
                lifted = (row, gap, doc.convert(start, from: nil).y - frame.minY)
            }
            guard let (row, gap, grab) = lifted else { return }
            _ = (doc.superview as? NSClipView)?.autoscroll(with: last)
            let p = doc.convert(last.locationInWindow, from: nil)
            row.frame.origin.y = min(max(p.y - grab, 0), max(stack.frame.maxY - row.frame.height, 0))
            // The gap goes after every other item whose middle is above the lifted row's middle.
            let others = stack.arrangedSubviews.filter { $0 !== gap }
            // Use the unclamped position so the pointer can carry a tab past the last row.
            let middle = p.y - grab + row.frame.height / 2
            let slot = others.filter { doc.convert($0.frame, from: stack).midY < middle }.count
            guard stack.arrangedSubviews.firstIndex(of: gap) != slot else { return }
            stack.removeArrangedSubview(gap)
            stack.insertArrangedSubview(gap, at: slot)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                stack.layoutSubtreeIfNeeded()
            }
        }
        guard let (row, gap, _) = lifted else { return }
        let slot = stack.arrangedSubviews.firstIndex(of: gap) ?? 0
        row.removeFromSuperview()
        gap.removeFromSuperview()
        dragging = false
        row.shadow = nil
        row.layer?.shadowOpacity = 0
        (row as? Row)?.refreshColors()
        var items = kinds
        items.removeAll { if case .row(let w) = $0 { w === ws } else { false } }
        let t = Self.dropTarget(items, slot: slot)
        actions?.move(ws, before: t.before, group: t.group)
    }

    /// Where a tab dropped into gap `slot` goes: in front of `before` (nil: the end), in `group`. A tab joins a group
    /// when dropped between two of its tabs or right under its expanded header, and leaves it anywhere else.
    static func dropTarget(_ items: [Item], slot: Int) -> (before: Workspace?, group: TabGroup?) {
        let above = slot > 0 ? items[slot - 1] : nil
        let below = slot < items.count ? items[slot] : nil
        let before: Workspace? = switch below {
        case .header(_, let first): first
        case .row(let ws): ws
        case nil: nil
        }
        switch (above, below) {
        case (.header(let g, _), _) where !g.collapsed: return (before, g)
        case (.row(let a), .row(let b)) where a.group != nil && a.group === b.group: return (before, a.group)
        default: return (before, nil)
        }
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Menu items hold their target weakly. Keep the last menu's owner alive even if its tab or group closes.
private var menuOwner: NSView?

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class Row: NSView, NSTextFieldDelegate {
    struct Model {
        let ws: Workspace
        let index: Int
        let title: String
        let cwd: String?
        let ports: [Int]
        let notification: String?
        let unread: Bool
        let waiting: Bool
        let working: Bool
        let selected: Bool
        let labels: [TabLabel]
        let group: TabGroup?

    }

    private let onClick: () -> Void
    private let ws: Workspace
    private let titleField = NSTextField(labelWithString: "")
    private let cwdField = Row.label("", .systemFont(ofSize: 11), .secondaryLabelColor, middle: true)
    private let portsField = Row.label("", .monospacedSystemFont(ofSize: 11, weight: .regular), .systemGreen)
    private let shortcut = Row.label("", .systemFont(ofSize: 10), .tertiaryLabelColor)
    private let head = NSStackView()
    private let bar = NSView()
    private let edge = NSView()
    private var chips: [NSTextField] = []
    private var model: Model
    private var pulseState = -1
    private struct ColorState: Equatable {
        let selected: Bool
        let waiting: Bool
        let unread: Bool
        let working: Bool
        let group: ObjectIdentifier?
        let groupColor: String?
        let labels: [TabLabel]

        init(_ model: Model) {
            selected = model.selected
            waiting = model.waiting
            unread = model.unread
            working = model.working
            group = model.group.map(ObjectIdentifier.init)
            groupColor = model.group?.color
            labels = model.labels
        }
    }
    private var colorState: ColorState?
    private var cancelled = false
    var onEditing: ((Bool) -> Void)?
    weak var actions: TabGroupActions?
    weak var sidebar: SidebarView?

    init(_ m: Model, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.ws = m.ws
        self.model = m
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let title = titleField
        title.font = .systemFont(ofSize: 13, weight: m.unread ? .bold : .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.delegate = self
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        head.addArrangedSubview(title)
        head.addArrangedSubview(NSView())
        head.addArrangedSubview(shortcut)
        head.spacing = 6

        // Always two lines so every row is the same height; the branch is in the titlebar strip and
        // the notification text is the tooltip.
        portsField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let second = NSStackView(views: [cwdField, portsField])
        second.spacing = 6
        let lines: [NSView] = [head, second]

        let v = NSStackView(views: lines)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            head.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
        for (indicator, leading) in [(bar, true), (edge, false)] {
            indicator.wantsLayer = true
            indicator.layer?.cornerRadius = 1.5
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            NSLayoutConstraint.activate([
                leading ? indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1)
                    : indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                indicator.widthAnchor.constraint(equalToConstant: 3),
                indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
        setAccessibilityRole(.button)
        update(m)
    }

    func update(_ m: Model) {
        let previous = model
        model = m
        if titleField.stringValue != m.title { titleField.stringValue = m.title }
        if titleField.font == nil || previous.unread != m.unread {
            titleField.font = .systemFont(ofSize: 13, weight: m.unread ? .bold : .medium)
        }
        if cwdField.stringValue != (m.cwd ?? "") { cwdField.stringValue = m.cwd ?? "" }
        if previous.ports != m.ports || portsField.stringValue.isEmpty {
            portsField.stringValue = m.ports.map { ":\($0)" }.joined(separator: " ")
        }
        let key = m.index <= 10 ? "⌘\(m.index % 10)" : ""
        if shortcut.stringValue != key { shortcut.stringValue = key }
        if toolTip != m.notification { toolTip = m.notification }
        while chips.count > m.labels.count { chips.removeLast().removeFromSuperview() }
        for (index, label) in m.labels.enumerated() {
            if index == chips.count {
                let chip = Self.chip(label)
                chips.append(chip)
                head.insertArrangedSubview(chip, at: index + 1)
            }
            let chip = chips[index]
            let text = " \(label.name) "
            if chip.stringValue != text { chip.stringValue = text }
        }
        let accessibility = m.waiting ? "\(m.title), needs input" : m.title
        if accessibilityLabel() != accessibility { setAccessibilityLabel(accessibility) }
        if colorState != ColorState(m) { refreshColors() }
    }

    func refreshColors() {
        let m = model
        colorState = ColorState(m)
        let background = m.selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil
        if layer?.backgroundColor != background { layer?.backgroundColor = background }
        let ungrouped = m.group == nil
        if bar.isHidden != ungrouped { bar.isHidden = ungrouped }
        let groupColor = m.group?.nsColor.cgColor
        if bar.layer?.backgroundColor != groupColor { bar.layer?.backgroundColor = groupColor }
        let inactive = !m.waiting && !m.unread && !m.working
        if edge.isHidden != inactive { edge.isHidden = inactive }
        let attentionColor = (m.waiting ? Attention.waiting : m.unread ? .news : .working).color.cgColor
        if edge.layer?.backgroundColor != attentionColor { edge.layer?.backgroundColor = attentionColor }
        for (chip, label) in zip(chips, m.labels) {
            if chip.textColor != label.textColor { chip.textColor = label.textColor }
            if chip.backgroundColor != label.nsColor { chip.backgroundColor = label.nsColor }
        }
        let state = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : m.waiting ? 1 : m.working ? 2 : 0
        guard state != pulseState else { return }
        pulseState = state
        edge.layer?.removeAnimation(forKey: "pulse")
        guard state != 0 else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = state == 1 ? 0.15 : 0.3
        pulse.duration = state == 1 ? 0.5 : 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        edge.layer?.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Labels would take clicks on the row's text; only the title being renamed keeps its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return titleField.currentEditor() != nil && hit.isDescendant(of: titleField) ? hit : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return beginEditing() }
        onClick()
        sidebar?.trackDrag(ws, from: event)
    }

    // MARK: Title editing

    @objc func beginEditing() {
        cancelled = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.drawsBackground = true
        titleField.backgroundColor = .textBackgroundColor
        titleField.stringValue = ws.customTitle ?? ws.title
        // Freeze the sidebar only if editing really began; otherwise it would never end and unfreeze.
        guard window?.makeFirstResponder(titleField) == true, titleField.currentEditor() != nil else {
            titleField.isEditable = false
            titleField.isSelectable = false
            titleField.drawsBackground = false
            return
        }
        onEditing?(true)
        titleField.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        window?.makeFirstResponder(nil) // ends editing without saving
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !cancelled {
            let t = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            ws.customTitle = t.isEmpty ? nil : t // empty goes back to the automatic title
        }
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        onEditing?(false)
        // Back to the terminal only on Return or Esc; a click elsewhere already chose where focus goes.
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        if cancelled || movement == NSTextMovement.return.rawValue { onClick() }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        menuOwner = self
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab", action: #selector(renameFromMenu), keyEquivalent: "").target = self
        if ws.customTitle != nil {
            menu.addItem(withTitle: "Use Automatic Title", action: #selector(clearTitle), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let labels = NSMenu()
        for l in LabelStore.all {
            let item = labels.addItem(withTitle: l.name, action: #selector(toggleLabel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l.name
            item.image = Self.swatch(l.nsColor)
            item.state = ws.labels.contains(l.name) ? .on : .off
        }
        if !LabelStore.all.isEmpty { labels.addItem(.separator()) }
        labels.addItem(withTitle: "New Label…", action: #selector(newLabel), keyEquivalent: "").target = self
        if !LabelStore.all.isEmpty {
            let delete = NSMenu()
            for l in LabelStore.all {
                let item = delete.addItem(withTitle: l.name, action: #selector(deleteLabel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = l.name
                item.image = Self.swatch(l.nsColor)
            }
            labels.addItem(withTitle: "Delete Label", action: nil, keyEquivalent: "").submenu = delete
        }
        menu.addItem(withTitle: "Labels", action: nil, keyEquivalent: "").submenu = labels
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Tab to New Group", action: #selector(addToNewGroup), keyEquivalent: "").target = self
        let others = (actions?.groups ?? []).filter { $0 !== ws.group }
        if !others.isEmpty {
            let sub = NSMenu()
            for g in others {
                let item = sub.addItem(withTitle: g.displayName,
                                       action: #selector(addToGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = g
                item.image = Self.swatch(g.nsColor)
            }
            menu.addItem(withTitle: "Add Tab to Group", action: nil, keyEquivalent: "").submenu = sub
        }
        if ws.group != nil {
            menu.addItem(withTitle: "Remove from Group", action: #selector(removeFromGroup), keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func renameFromMenu() { sidebar?.rename(ws) }
    @objc private func addToNewGroup() { actions?.addToNewGroup(ws) }
    @objc private func removeFromGroup() { actions?.removeFromGroup(ws) }

    @objc private func addToGroup(_ sender: NSMenuItem) {
        // The group may have gone away while the menu was open.
        guard let g = sender.representedObject as? TabGroup, actions?.groups.contains(where: { $0 === g }) == true else { return }
        actions?.add(ws, to: g)
    }

    @objc private func clearTitle() {
        ws.customTitle = nil
        ws.onChange?()
    }

    @objc private func toggleLabel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if ws.labels.contains(name) { ws.labels.removeAll { $0 == name } } else { ws.labels.append(name) }
        ws.onChange?()
    }

    @objc private func deleteLabel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        LabelStore.delete(name) // tabs keep the name, so recreating the label brings it back
        ws.onChange?()
    }

    @objc private func newLabel() {
        let alert = NSAlert()
        alert.messageText = "New Label"
        alert.informativeText = "Labels are shared by all tabs. Reusing a name changes that label's color."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        name.placeholderString = "Name"
        let color = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for p in TabLabel.palette {
            color.addItem(withTitle: p.name)
            color.lastItem?.image = Self.swatch(p.color)
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        box.addSubview(name)
        box.addSubview(color)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let c = color.titleOfSelectedItem else { return }
        LabelStore.save(TabLabel(name: n, color: c))
        if !ws.labels.contains(n) { ws.labels.append(n) }
        ws.onChange?()
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }

    private static func chip(_ l: TabLabel) -> NSTextField {
        let t = NSTextField(labelWithString: " \(l.name) ")
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = l.textColor
        t.drawsBackground = true
        t.backgroundColor = l.nsColor
        t.wantsLayer = true
        t.layer?.cornerRadius = 4
        t.layer?.masksToBounds = true
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    private static func label(_ s: String, _ font: NSFont, _ color: NSColor, middle: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        l.lineBreakMode = middle ? .byTruncatingMiddle : .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
}

/// What the sidebar asks the window to do with tab groups.
protocol TabGroupActions: AnyObject {
    var groups: [TabGroup] { get }
    func addToNewGroup(_ ws: Workspace)
    func add(_ ws: Workspace, to group: TabGroup)
    func removeFromGroup(_ ws: Workspace)
    func toggleCollapsed(_ group: TabGroup)
    func ungroup(_ group: TabGroup)
    func closeGroup(_ group: TabGroup)
    func newTab(in group: TabGroup)
    func groupsChanged()
    func move(_ ws: Workspace, before: Workspace?, group: TabGroup?)
}

/// A group's header: chevron, colored name pill, and when collapsed the tab count and any attention signal.
final class GroupHeader: NSView {
    struct Model {
        let group: TabGroup
        let count: Int
        let unread: Bool
        let waiting: Bool
        let working: Bool

    }

    private var model: Model
    private weak var actions: TabGroupActions?
    private let pill = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: " needs input ")
    private let dot = NSView()
    private var collapsed: Bool?
    private struct State: Equatable {
        let group: ObjectIdentifier
        let name: String
        let color: String
        let collapsed: Bool
        let count: Int
        let unread: Bool
        let waiting: Bool
        let working: Bool

        init(_ model: Model) {
            group = ObjectIdentifier(model.group)
            name = model.group.name
            color = model.group.color
            collapsed = model.group.collapsed
            count = model.count
            unread = model.unread
            waiting = model.waiting
            working = model.working
        }
    }
    private var state: State?

    init(_ m: Model, actions: TabGroupActions?) {
        model = m
        self.actions = actions
        super.init(frame: .zero)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        pill.font = .systemFont(ofSize: 11, weight: .semibold)
        pill.drawsBackground = true
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.layer?.masksToBounds = true
        pill.lineBreakMode = .byTruncatingTail
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let h = NSStackView(views: [chevron, pill, count, NSView(), badge, dot])
        h.spacing = 6
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ model: Model, actions: TabGroupActions?) {
        self.model = model
        self.actions = actions
        if state != State(model) { refresh() }
    }

    /// Re-reads the group's name and color (live while the editor popover is open).
    func refresh() {
        state = State(model)
        let g = model.group
        let text = " \(g.displayName) "
        if pill.stringValue != text { pill.stringValue = text }
        if pill.backgroundColor != g.nsColor { pill.backgroundColor = g.nsColor }
        if pill.textColor != g.textColor { pill.textColor = g.textColor }
        if collapsed != g.collapsed {
            collapsed = g.collapsed
            chevron.image = NSImage(systemSymbolName: g.collapsed ? "chevron.right" : "chevron.down",
                                    accessibilityDescription: nil)
        }
        let countText = "\(model.count)"
        if count.stringValue != countText { count.stringValue = countText }
        if count.isHidden == g.collapsed { count.isHidden = !g.collapsed }
        let hideBadge = !g.collapsed || !model.waiting
        if badge.isHidden != hideBadge { badge.isHidden = hideBadge }
        if badge.backgroundColor != Attention.waiting.color { badge.backgroundColor = Attention.waiting.color }
        let hideDot = !g.collapsed || model.waiting || (!model.unread && !model.working)
        if dot.isHidden != hideDot { dot.isHidden = hideDot }
        let dotColor = (model.unread ? Attention.news : .working).color.cgColor
        if dot.layer?.backgroundColor != dotColor { dot.layer?.backgroundColor = dotColor }
        let accessibility = "Group \(g.displayName), \(model.count) tabs, \(g.collapsed ? "collapsed" : "expanded")"
        if accessibilityLabel() != accessibility { setAccessibilityLabel(accessibility) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The second click of a double-click would undo the first.
        guard event.clickCount == 1 else { return }
        actions?.toggleCollapsed(model.group)
    }

    override func accessibilityPerformPress() -> Bool { actions?.toggleCollapsed(model.group); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuOwner = self
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit Name and Color…", action: #selector(edit), keyEquivalent: "").target = self
        menu.addItem(withTitle: model.group.collapsed ? "Expand Group" : "Collapse Group",
                     action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Tab in Group", action: #selector(newTab), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ungroup", action: #selector(ungroup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Group", action: #selector(closeGroup), keyEquivalent: "").target = self
        return menu
    }

    weak var sidebar: SidebarView?

    @objc private func edit() { sidebar?.editGroup(model.group) }
    @objc private func toggle() { actions?.toggleCollapsed(model.group) }
    @objc private func newTab() { actions?.newTab(in: model.group) }
    @objc private func ungroup() { actions?.ungroup(model.group) }
    @objc private func closeGroup() { actions?.closeGroup(model.group) }
}
