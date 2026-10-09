import AppKit

/// Vertical tab list: title, branch, cwd, ports and the latest notification per workspace.
final class SidebarView: NSVisualEffectView, NSPopoverDelegate {
    var onSelect: ((Workspace) -> Void)?

    private let stack = NSStackView()
    private var lastSignature = ""
    private var editing = false

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
        let rows = workspaces.enumerated().map { i, ws in
            Row.Model(ws: ws, index: i + 1, title: ws.title, cwd: ws.cwd.map(Self.abbreviate),
                      branch: ws.branch, ports: ws.ports, notification: ws.notification,
                      unread: ws.unread, waiting: ws.waiting, selected: ws === selected,
                      labels: ws.labels.compactMap(LabelStore.label(named:)), group: ws.group)
        }
        // A group header goes before the first tab of each group; tabs of collapsed groups are hidden.
        var items: [(sig: String, make: () -> NSView)] = []
        var lastGroup: TabGroup?
        for model in rows {
            if let g = model.ws.group, g !== lastGroup {
                let members = rows.filter { $0.ws.group === g }
                let header = GroupHeader.Model(group: g, count: members.count,
                                               unread: members.contains { $0.unread }, waiting: members.contains { $0.waiting })
                items.append((header.signature, { [weak self] in
                    let h = GroupHeader(header, actions: self?.actions)
                    self?.headers[g.id] = h
                    return h
                }))
            }
            lastGroup = model.ws.group
            if model.ws.group?.collapsed == true { continue }
            items.append((model.signature, { [weak self] in
                let row = Row(model) { [weak self] in self?.onSelect?(model.ws) }
                row.actions = self?.actions
                row.onEditing = { [weak self] on in
                    self?.editing = on
                    if !on { self?.lastSignature = ""; model.ws.onChange?() }
                }
                return row
            }))
        }
        // The poll timer calls this every few seconds; skip rebuilding when nothing changed.
        let sig = items.map(\.sig).joined(separator: "\u{1}")
        // Rebuilding would throw away a title being edited; the end of editing triggers an update.
        guard sig != lastSignature, !editing else { return }
        lastSignature = sig

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headers = [:]
        for item in items {
            let v = item.make()
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    weak var actions: TabGroupActions?
    private var headers: [String: GroupHeader] = [:]

    /// Opens the "Name this group" popover on a group's header; the sidebar holds still while it's open.
    func editGroup(_ group: TabGroup) {
        guard let header = headers[group.id] else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GroupEditor(group: group) { [weak header] in header?.refresh() }
        popover.delegate = self
        editing = true
        popover.show(relativeTo: header.bounds, of: header, preferredEdge: .maxX)
    }

    func popoverDidClose(_ notification: Notification) {
        editing = false
        lastSignature = ""
        actions?.groupsChanged()
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class Row: NSView, NSTextFieldDelegate {
    struct Model {
        let ws: Workspace
        let index: Int
        let title: String
        let cwd: String?
        let branch: String?
        let ports: [Int]
        let notification: String?
        let unread: Bool
        let waiting: Bool
        let selected: Bool
        let labels: [TabLabel]
        let group: TabGroup?

        var signature: String {
            "\(ws.id)|\(index)|\(title)|\(cwd ?? "")|\(branch ?? "")|\(ports)|\(notification ?? "")|\(unread)|\(waiting)|\(selected)|"
                + labels.map { $0.name + ":" + $0.color }.joined(separator: ",") + "|" + (group.map { $0.id + $0.color } ?? "")
        }
    }

    private let onClick: () -> Void
    private let ws: Workspace
    private let titleField = NSTextField(labelWithString: "")
    private var cancelled = false
    var onEditing: ((Bool) -> Void)?
    weak var actions: TabGroupActions?

    init(_ m: Model, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.ws = m.ws
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if m.selected { layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor }

        let title = titleField
        title.stringValue = m.title
        title.font = .systemFont(ofSize: 13, weight: m.unread ? .bold : .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.delegate = self
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.isHidden = !m.unread
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let shortcut = Self.label(m.index <= 9 ? "⌘\(m.index)" : "", .systemFont(ofSize: 10), .tertiaryLabelColor)
        let badge = Self.label("needs input", .systemFont(ofSize: 10, weight: .semibold), .white)
        badge.drawsBackground = true
        badge.backgroundColor = .systemOrange
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.isHidden = !m.waiting
        let head = NSStackView(views: [dot, title, NSView(), badge, shortcut])
        head.spacing = 6
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var lines: [NSView] = [head]
        if !m.labels.isEmpty {
            let chips = NSStackView(views: m.labels.map(Self.chip))
            chips.spacing = 4
            lines.append(chips)
        }
        let small = NSFont.systemFont(ofSize: 11)
        if let b = m.branch { lines.append(Self.label("⎇ " + b, small, .secondaryLabelColor)) }
        if let c = m.cwd { lines.append(Self.label(c, small, .secondaryLabelColor, middle: true)) }
        if !m.ports.isEmpty {
            lines.append(Self.label(m.ports.map { ":\($0)" }.joined(separator: " "),
                                    .monospacedSystemFont(ofSize: 11, weight: .regular), .systemGreen))
        }
        if let n = m.notification {
            let l = NSTextField(wrappingLabelWithString: n)
            l.font = small
            l.textColor = m.unread ? .systemBlue : .tertiaryLabelColor
            l.cell?.truncatesLastVisibleLine = true
            l.maximumNumberOfLines = 4
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            notificationLabel = l
            lines.append(l)
        }

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
        if let g = m.group {
            // Grouped tabs carry a bar in the group's color, like Chrome's group outline.
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = g.nsColor.cgColor
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                bar.widthAnchor.constraint(equalToConstant: 3),
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(m.waiting ? "\(m.title), needs input" : m.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var notificationLabel: NSTextField?
    private var contentInset: CGFloat { 16 }

    override func layout() {
        // Wrap the notification to the row's real width so its height matches its lines.
        if let l = notificationLabel, bounds.width > contentInset,
           l.preferredMaxLayoutWidth != bounds.width - contentInset {
            l.preferredMaxLayoutWidth = bounds.width - contentInset
        }
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginEditing() } else { onClick() }
    }

    // MARK: Title editing

    @objc func beginEditing() {
        cancelled = false
        onEditing?(true)
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.drawsBackground = true
        titleField.backgroundColor = .textBackgroundColor
        titleField.stringValue = ws.customTitle ?? ws.title
        window?.makeFirstResponder(titleField)
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
        onEditing?(false)
        onClick() // back to the terminal
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab", action: #selector(beginEditing), keyEquivalent: "").target = self
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
            for (i, g) in others.enumerated() {
                let item = sub.addItem(withTitle: g.name.isEmpty ? "Unnamed group" : g.name,
                                       action: #selector(addToGroup(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.image = Self.swatch(g.nsColor)
            }
            menu.addItem(withTitle: "Add Tab to Group", action: nil, keyEquivalent: "").submenu = sub
        }
        if ws.group != nil {
            menu.addItem(withTitle: "Remove from Group", action: #selector(removeFromGroup), keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func addToNewGroup() { actions?.addToNewGroup(ws) }
    @objc private func removeFromGroup() { actions?.removeFromGroup(ws) }

    @objc private func addToGroup(_ sender: NSMenuItem) {
        let others = (actions?.groups ?? []).filter { $0 !== ws.group }
        guard others.indices.contains(sender.tag) else { return }
        actions?.add(ws, to: others[sender.tag])
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

    private static func chip(_ l: TabLabel) -> NSView {
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
}

/// A group's header: chevron, colored name pill, and when collapsed the tab count and any attention signal.
private final class GroupHeader: NSView {
    struct Model {
        let group: TabGroup
        let count: Int
        let unread: Bool
        let waiting: Bool

        var signature: String {
            "group|\(group.id)|\(group.name)|\(group.color)|\(group.collapsed)|\(count)|\(unread)|\(waiting)"
        }
    }

    private let model: Model
    private weak var actions: TabGroupActions?
    private let pill = NSTextField(labelWithString: "")

    init(_ m: Model, actions: TabGroupActions?) {
        model = m
        self.actions = actions
        super.init(frame: .zero)
        let chevron = NSImageView(image: NSImage(systemSymbolName: m.group.collapsed ? "chevron.right" : "chevron.down",
                                                 accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        pill.font = .systemFont(ofSize: 11, weight: .semibold)
        pill.drawsBackground = true
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.layer?.masksToBounds = true
        pill.lineBreakMode = .byTruncatingTail
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh()

        var views: [NSView] = [chevron, pill]
        if m.group.collapsed {
            let count = NSTextField(labelWithString: "\(m.count)")
            count.font = .systemFont(ofSize: 11)
            count.textColor = .secondaryLabelColor
            views.append(count)
        }
        views.append(NSView())
        if m.group.collapsed && m.waiting {
            let badge = NSTextField(labelWithString: " needs input ")
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .white
            badge.drawsBackground = true
            badge.backgroundColor = .systemOrange
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.masksToBounds = true
            views.append(badge)
        } else if m.group.collapsed && m.unread {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
            views.append(dot)
        }
        let h = NSStackView(views: views)
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
        setAccessibilityLabel("Group \(m.group.name), \(m.count) tabs, \(m.group.collapsed ? "collapsed" : "expanded")")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Re-reads the group's name and color (live while the editor popover is open).
    func refresh() {
        let g = model.group
        pill.stringValue = g.name.isEmpty ? "   " : " \(g.name) "
        pill.backgroundColor = g.nsColor
        pill.textColor = g.textColor
    }

    override func mouseDown(with event: NSEvent) {
        actions?.toggleCollapsed(model.group)
    }

    override func accessibilityPerformPress() -> Bool { actions?.toggleCollapsed(model.group); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
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

    private var sidebar: SidebarView? {
        var v = superview
        while let s = v, !(s is SidebarView) { v = s.superview }
        return v as? SidebarView
    }

    @objc private func edit() { sidebar?.editGroup(model.group) }
    @objc private func toggle() { actions?.toggleCollapsed(model.group) }
    @objc private func newTab() { actions?.newTab(in: model.group) }
    @objc private func ungroup() { actions?.ungroup(model.group) }
    @objc private func closeGroup() { actions?.closeGroup(model.group) }
}
