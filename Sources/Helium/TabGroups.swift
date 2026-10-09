import AppKit

/// A Chrome-style tab group: a named, colored, collapsible run of tabs in the sidebar.
final class TabGroup {
    /// Chrome's group colors.
    static let colors: [(name: String, color: NSColor)] = [
        ("Gray", .systemGray), ("Blue", .systemBlue), ("Red", .systemRed), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Pink", .systemPink), ("Purple", .systemPurple), ("Cyan", .systemTeal),
        ("Orange", .systemOrange),
    ]

    let id: String
    var name: String
    var color: String
    var collapsed = false

    init(id: String = UUID().uuidString, name: String = "", color: String = "Blue", collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    var displayName: String { name.isEmpty ? "Unnamed group" : name }
    var nsColor: NSColor { Self.colors.first { $0.name == color }?.color ?? .systemGray }
    var textColor: NSColor { color == "Yellow" ? .black : .white }
}

/// The "Name this group" popover: a name field and Chrome's color dots, applied as you edit.
final class GroupEditor: NSViewController, NSTextFieldDelegate {
    private let group: TabGroup
    private let onChange: () -> Void
    private let field = NSTextField()

    init(group: TabGroup, onChange: @escaping () -> Void) {
        self.group = group
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        field.placeholderString = "Name this group"
        field.stringValue = group.name
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 236).isActive = true

        let dots = NSStackView(views: TabGroup.colors.map { c in
            let b = NSButton(image: Self.dot(c.color, selected: c.name == group.color), target: self,
                             action: #selector(pick(_:)))
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(c.name)
            b.setAccessibilityLabel(c.name)
            return b
        })
        dots.spacing = 6

        let stack = NSStackView(views: [field, dots])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) {
        group.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        onChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:))
        else { return false }
        view.window?.performClose(nil) // Enter or Esc closes the popover; edits are already applied
        return true
    }

    @objc private func pick(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        group.color = name
        for case let b as NSButton in (sender.superview?.subviews ?? []) {
            let c = TabGroup.colors.first { $0.name == b.identifier?.rawValue }
            b.image = Self.dot(c?.color ?? .gray, selected: b === sender)
        }
        onChange()
    }

    private static func dot(_ color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: selected ? 4 : 2, dy: selected ? 4 : 2)).fill()
            if selected {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }
}
