import AppKit
import GhosttyKit

/// Helium's config file: Ghostty syntax (`key = value`), loaded after the user's
/// Ghostty config. Only keys set from Settings are written; other lines are kept.
enum HeliumConfig {
    static var path: String { Ghostty.heliumConfigPath }

    static func read() -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let (k, v) = parse(line) else { continue }
            values[k] = v
        }
        return values
    }

    /// Sets `key`, or removes it (back to the Ghostty value) when `value` is nil or empty.
    static func set(_ key: String, _ value: String?) {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? "# Written by Helium's Settings window. Ghostty config syntax; overrides your Ghostty config.\n"
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { parse(Substring($0))?.0 == key }
        if let value, !value.isEmpty {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key) = \(value)")
            lines.append("")
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func parse(_ line: Substring) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        let k = t[..<eq].trimmingCharacters(in: .whitespaces)
        let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : (k, v)
    }

    /// Output of libghostty's `+show-config`, run through this binary, with Helium's
    /// overrides applied (the CLI action only reads the Ghostty config files).
    static func showConfig(docs: Bool) -> String {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["+show-config"] + (docs ? ["--docs"] : [])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "Could not run +show-config." }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var text = String(data: data, encoding: .utf8) ?? ""
        for (k, v) in read() {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.hasPrefix("\(k) = ") || line == "\(k) =" ? "\(k) = \(v)" : String(line)
            }.joined(separator: "\n")
        }
        return text
    }

    static func effectiveValues() -> [String: String] {
        var values: [String: String] = [:]
        for line in showConfig(docs: false).split(separator: "\n") {
            if let (k, v) = parse(line), values[k] == nil { values[k] = v }
        }
        return values
    }
}

extension Notification.Name {
    static let heliumSidebarWidthChanged = Notification.Name("HeliumSidebarWidthChanged")
}

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var values: [String: String] = [:]
    private let terminalGrid = NSGridView()
    private let allText = NSTextView()
    private let docsToggle = NSButton(checkboxWithTitle: "Show documentation", target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Helium Settings"
        window.minSize = NSSize(width: 520, height: 420)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HeliumSettings")

        let tabs = NSTabView()
        tabs.addTabViewItem(item("Terminal", terminalTab()))
        tabs.addTabViewItem(item("Helium", heliumTab()))
        tabs.addTabViewItem(item("All Options", allOptionsTab()))
        window.contentView = tabs
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        if window?.isVisible != true { window?.center() }
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        // +show-config is a subprocess (~0.1 s); keep the UI responsive while it runs.
        let docs = docsToggle.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            let values = HeliumConfig.effectiveValues()
            let all = HeliumConfig.showConfig(docs: docs)
            DispatchQueue.main.async {
                self.values = values
                self.rebuildTerminalGrid()
                self.allText.string = all
            }
        }
    }

    private func item(_ label: String, _ view: NSView) -> NSTabViewItem {
        let i = NSTabViewItem(identifier: label)
        i.label = label
        i.view = view
        return i
    }

    // MARK: Terminal

    private func terminalTab() -> NSView {
        terminalGrid.rowSpacing = 10
        terminalGrid.columnSpacing = 12
        terminalGrid.translatesAutoresizingMaskIntoConstraints = false

        let note = label("Saved to Helium's config file, which overrides your Ghostty config. "
                         + "Clear a field to go back to the Ghostty value. Changes apply to open terminals.", secondary: true)
        let buttons = NSStackView(views: [
            button("Open Helium Config", #selector(openHeliumConfig)),
            button("Open Ghostty Config", #selector(openGhosttyConfig)),
        ])
        let stack = NSStackView(views: [terminalGrid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        return padded(stack)
    }

    private struct Choice { let title: String; let value: String }

    private func rebuildTerminalGrid() {
        while terminalGrid.numberOfRows > 0 { terminalGrid.removeRow(at: 0) }
        let fonts = Array(Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
        rowText("Font family", "font-family", placeholder: "JetBrains Mono (built in)", suggestions: fonts)
        rowText("Font size", "font-size", placeholder: "13")
        rowText("Theme", "theme", placeholder: "light:Name,dark:Name", suggestions: themeNames())
        rowChoice("Cursor style", "cursor-style", [
            .init(title: "Block", value: "block"), .init(title: "Bar", value: "bar"),
            .init(title: "Underline", value: "underline"), .init(title: "Hollow block", value: "block_hollow"),
        ])
        rowChoice("Cursor blink", "cursor-style-blink", [
            .init(title: "Default (programs decide)", value: ""), .init(title: "On", value: "true"),
            .init(title: "Off", value: "false"),
        ])
        rowText("Background opacity", "background-opacity", placeholder: "1 (0 to 1)")
        rowText("Padding (points)", "window-padding-x", alsoKey: "window-padding-y", placeholder: "2")
        rowText("Scrollback (bytes)", "scrollback-limit-bytes", placeholder: "50000000")
        rowChoice("Option key as Alt", "macos-option-as-alt", [
            .init(title: "Default for your keyboard", value: ""), .init(title: "Off", value: "false"),
            .init(title: "Both", value: "true"), .init(title: "Left only", value: "left"),
            .init(title: "Right only", value: "right"),
        ])
        rowChoice("Copy on select", "copy-on-select", [
            .init(title: "Off", value: "none"), .init(title: "To clipboard", value: "clipboard"),
        ])
        rowChoice("Hide mouse while typing", "mouse-hide-while-typing", [
            .init(title: "Off", value: "false"), .init(title: "On", value: "true"),
        ])
        rowChoice("Confirm closing", "confirm-close-surface", [
            .init(title: "When a program is running", value: "true"), .init(title: "Never", value: "false"),
            .init(title: "Always", value: "always"),
        ])
        terminalGrid.column(at: 0).xPlacement = .trailing
    }

    private func rowText(_ title: String, _ key: String, alsoKey: String? = nil, placeholder: String,
                         suggestions: [String] = []) {
        let field: NSTextField
        if suggestions.isEmpty {
            field = NSTextField()
        } else {
            let combo = NSComboBox()
            combo.addItems(withObjectValues: suggestions)
            combo.completes = true
            field = combo
        }
        field.placeholderString = placeholder
        field.stringValue = values[key] ?? ""
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        field.target = self
        field.action = #selector(textChanged(_:))
        field.identifier = NSUserInterfaceItemIdentifier([key, alsoKey].compactMap { $0 }.joined(separator: ","))
        terminalGrid.addRow(with: [label(title + ":"), field])
    }

    private func rowChoice(_ title: String, _ key: String, _ choices: [Choice]) {
        let popup = NSPopUpButton()
        for c in choices {
            popup.addItem(withTitle: c.title)
            popup.lastItem?.representedObject = c.value
        }
        let current = values[key] ?? ""
        let match = choices.firstIndex { $0.value == current }
            ?? choices.firstIndex { $0.value == "" } ?? 0
        popup.selectItem(at: match)
        popup.target = self
        popup.action = #selector(choiceChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(key)
        terminalGrid.addRow(with: [label(title + ":"), popup])
    }

    @objc private func textChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        for key in (sender.identifier?.rawValue ?? "").split(separator: ",") {
            HeliumConfig.set(String(key), value)
        }
        Ghostty.shared.reloadConfig()
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        HeliumConfig.set(key, sender.selectedItem?.representedObject as? String)
        Ghostty.shared.reloadConfig()
    }

    private func themeNames() -> [String] {
        // Themes aren't bundled; offer the user's own and Ghostty.app's if installed.
        let dirs = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/themes").path,
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
        return Array(Set(dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })).sorted()
    }

    @objc private func openHeliumConfig() {
        if !FileManager.default.fileExists(atPath: HeliumConfig.path) { HeliumConfig.set("", nil) } // writes the header
        NSWorkspace.shared.open(URL(fileURLWithPath: HeliumConfig.path))
    }

    @objc private func openGhosttyConfig() {
        let s = ghostty_config_open_path()
        defer { ghostty_string_free(s) }
        guard let p = s.ptr, s.len > 0,
              let path = String(data: Data(bytes: p, count: Int(s.len)), encoding: .utf8) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: Helium

    private func heliumTab() -> NSView {
        let width = NSSlider(value: currentSidebarWidth(), minValue: 160, maxValue: 520,
                             target: self, action: #selector(sidebarWidthChanged(_:)))
        width.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let grid = NSGridView(views: [[label("Sidebar width:"), width]])
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 12

        let behavior = label("""
        Notifications: a pane gets a blue ring, and its tab a dot and the message, when a program \
        sends a desktop notification (OSC 9 or OSC 777), rings the bell, or runs `helium notify`. \
        The ring clears when you focus the pane. When an agent is waiting for your input or permission, \
        the ring is orange and the tab shows "needs input" until you type in that pane.

        Sidebar: branch, folder and listening ports refresh every 3 seconds, read from git files \
        and the process table without running any commands.

        Rendering: hidden tabs, and windows that are covered or minimized, stop drawing and \
        release their GPU memory. A window in the background stops blinking its cursor.

        Automation: the `helium` command and the socket at \(SocketServer.path) (owner only). \
        Each pane sets $HELIUM_PANE, so `helium notify` from inside a pane rings that pane.

        Keys come from your Ghostty keybinds: ⌘T new tab, ⌘D split right, ⇧⌘D split down, \
        ⌘W close, ⌘1–9 switch tab, ⌘[ and ⌘] previous and next split, ⌘, settings.
        """, secondary: true)
        behavior.preferredMaxLayoutWidth = 560

        let auto = NSButton(checkboxWithTitle: "Check for updates automatically", target: self,
                            action: #selector(autoUpdateToggled(_:)))
        auto.state = Updater.shared.automatic ? .on : .off
        let checkNow = button("Check Now", #selector(checkForUpdates))
        let updates = NSStackView(views: [auto, checkNow, updateStatus])
        updates.spacing = 12
        updateStatus.textColor = .secondaryLabelColor
        if let reason = Updater.shared.unavailableReason {
            auto.isEnabled = false
            checkNow.isEnabled = false
            updateStatus.stringValue = reason
        }
        NotificationCenter.default.addObserver(forName: .heliumUpdaterChanged, object: nil, queue: .main) {
            [weak self] _ in self?.showUpdateState()
        }

        let stack = NSStackView(views: [grid, updates, behavior])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        return padded(stack)
    }

    private let updateStatus = NSTextField(labelWithString: "")

    @objc private func autoUpdateToggled(_ sender: NSButton) { Updater.shared.automatic = sender.state == .on }

    @objc private func checkForUpdates() { Updater.shared.check() }

    private func showUpdateState() {
        updateStatus.stringValue = switch Updater.shared.state {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Helium is up to date."
        case .downloading(let v): "Downloading \(v)…"
        case .ready(let v): "\(v) is installed. Relaunch to start it."
        case .failed(let e): "Update failed: \(e)"
        }
    }

    private func currentSidebarWidth() -> Double {
        let w = UserDefaults.standard.double(forKey: "SidebarWidth")
        return w > 0 ? w : 240
    }

    @objc private func sidebarWidthChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "SidebarWidth")
        NotificationCenter.default.post(name: .heliumSidebarWidthChanged, object: nil)
    }

    // MARK: All options

    private func allOptionsTab() -> NSView {
        allText.isEditable = false
        allText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        allText.usesFindBar = true
        allText.isIncrementalSearchingEnabled = true
        allText.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = allText
        scroll.hasVerticalScroller = true
        allText.autoresizingMask = [.width]
        allText.isVerticallyResizable = true
        allText.minSize = NSSize(width: 0, height: 0)
        allText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        allText.textContainer?.widthTracksTextView = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        docsToggle.target = self
        docsToggle.action = #selector(docsToggled)
        let hint = label("Every Ghostty option with its current value. ⌘F to search. "
                         + "Set any of them in the Helium or Ghostty config file.", secondary: true)
        let top = NSStackView(views: [docsToggle, hint])
        top.spacing = 12

        let stack = NSStackView(views: [top, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let v = padded(stack, fill: true)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return v
    }

    @objc private func docsToggled() { refresh() }

    // MARK: Helpers

    private func label(_ s: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        if secondary {
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 12)
        }
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func padded(_ content: NSView, fill: Bool = false) -> NSView {
        let v = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            fill ? content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20)
                 : content.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -20),
        ])
        return v
    }
}
