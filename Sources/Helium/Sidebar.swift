import AppKit

/// Vertical tab list: title, branch, cwd, ports and the latest notification per workspace.
final class SidebarView: NSVisualEffectView {
    var onSelect: ((Workspace) -> Void)?
    var onNew: (() -> Void)?

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

        let add = NSButton(title: "New Tab", target: self, action: #selector(newTab))
        add.bezelStyle = .accessoryBarAction
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        add.imagePosition = .imageLeading
        add.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(add)

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
            update.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            update.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            update.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        NotificationCenter.default.addObserver(forName: .heliumUpdaterChanged, object: nil, queue: .main) {
            [weak self] _ in self?.updaterChanged()
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            add.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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

    @objc private func newTab() { onNew?() }

    private let update = NSButton(title: "", target: nil, action: nil)

    private func updaterChanged() {
        guard case .ready(let version) = Updater.shared.state else { return update.isHidden = true }
        update.title = "Relaunch for \(version)"
        update.toolTip = "Helium \(version) is installed. Relaunch to start it; open terminals will close."
        update.isHidden = false
    }

    @objc private func relaunchToUpdate() { Updater.shared.relaunch() }

    func update(_ workspaces: [Workspace], selected: Workspace?) {
        let rows = workspaces.enumerated().map { i, ws in
            Row.Model(ws: ws, index: i + 1, title: ws.title, cwd: ws.cwd.map(Self.abbreviate),
                      branch: ws.branch, ports: ws.ports, notification: ws.notification,
                      unread: ws.unread, selected: ws === selected)
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
        let selected: Bool

        var signature: String {
            "\(ws.id)|\(index)|\(title)|\(cwd ?? "")|\(branch ?? "")|\(ports)|\(notification ?? "")|\(unread)|\(selected)"
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
        let head = NSStackView(views: [dot, title, NSView(), shortcut])
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
            let l = Self.label(n, small, m.unread ? .systemBlue : .tertiaryLabelColor)
            l.lineBreakMode = .byWordWrapping
            l.cell?.truncatesLastVisibleLine = true
            l.maximumNumberOfLines = 2
            l.preferredMaxLayoutWidth = 200
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
        setAccessibilityLabel(m.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
