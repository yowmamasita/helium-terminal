import AppKit

/// Vertical tab list: title, branch, cwd, ports and the latest notification per workspace.
final class SidebarView: NSVisualEffectView {
    var onSelect: ((Workspace) -> Void)?

    private let stack = NSStackView()
    private var lastSignature = ""

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
                      unread: ws.unread, waiting: ws.waiting, selected: ws === selected)
        }
        // The poll timer calls this every few seconds; skip rebuilding when nothing changed.
        let sig = rows.map(\.signature).joined(separator: "\u{1}")
        guard sig != lastSignature else { return }
        lastSignature = sig

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for model in rows {
            let row = Row(model) { [weak self] in self?.onSelect?(model.ws) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class Row: NSView {
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

        var signature: String {
            "\(ws.id)|\(index)|\(title)|\(cwd ?? "")|\(branch ?? "")|\(ports)|\(notification ?? "")|\(unread)|\(waiting)|\(selected)"
        }
    }

    private let onClick: () -> Void

    init(_ m: Model, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if m.selected { layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor }

        let title = Self.label(m.title, .systemFont(ofSize: 13, weight: m.unread ? .bold : .medium), .labelColor)
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

    override func mouseDown(with event: NSEvent) { onClick() }
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
