import AppKit
import GhosttyKit

/// Owns the single libghostty app and routes its callbacks to the window.
/// libghostty takes C function pointers, which can't capture context, so the
/// callbacks go through `Ghostty.shared`.
final class Ghostty {
    static let shared = Ghostty()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    weak var window: MainWindowController?

    func start() -> Bool {
        config = Self.loadConfig()
        var rt = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { Ghostty.shared.tick() } },
            action_cb: { _, target, action in Ghostty.shared.handle(target, action) },
            read_clipboard_cb: { ud, loc, state, mimes, n, list in
                Ghostty.readClipboard(ud, loc, state, mimes, n, list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                Ghostty.confirmClipboard(ud, confirm, state, request)
            },
            write_clipboard_cb: { _, loc, content, n, confirm in
                Ghostty.writeClipboard(loc, content, n, confirm)
            },
            close_surface_cb: { ud, alive in
                guard let view = SurfaceView.from(ud) else { return }
                DispatchQueue.main.async { Ghostty.shared.window?.requestClose(view, processAlive: alive) }
            }
        )
        app = ghostty_app_new(&rt, config)
        setFocus(NSApp.isActive)
        return app != nil
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    var needsConfirmQuit: Bool {
        app.map { ghostty_app_needs_confirm_quit($0) } ?? false
    }

    /// Helium's own overrides, written by the Settings window. Loaded after the Ghostty
    /// config so it wins, without Helium ever rewriting a config shared with Ghostty.app.
    static var heliumConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/helium-terminal/config").path
    }

    private static func loadConfig() -> ghostty_config_t? {
        // Reads the user's Ghostty config, so themes, fonts and keybinds carry over.
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        // Last, so Settings win over the user's Ghostty config and the files it includes.
        if FileManager.default.fileExists(atPath: heliumConfigPath) {
            ghostty_config_load_file(cfg, heliumConfigPath)
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    func reloadConfig() {
        guard let app, let new = Self.loadConfig() else { return }
        ghostty_app_update_config(app, new)
        if let old = config { ghostty_config_free(old) }
        config = new
    }

    // MARK: Actions

    private func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view: SurfaceView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? SurfaceView.from(ghostty_surface_userdata(target.target.surface)) : nil
        guard let window else { return false }
        let a = action.action

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            window.newWorkspace(inheriting: view)
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view else { return false }
            window.split(view, a.new_split)
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let view else { return false }
            window.closeWorkspace(containing: view)
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            window.window?.performClose(nil)
        case GHOSTTY_ACTION_GOTO_TAB:
            window.gotoWorkspace(Int(a.goto_tab.rawValue))
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view else { return false }
            window.gotoSplit(from: view, a.goto_split)
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let view else { return false }
            window.equalize(containing: view)
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let t = a.set_title.title else { return false }
            view.title = String(cString: t)
            window.metadataChanged()
        case GHOSTTY_ACTION_PWD:
            guard let view, let p = a.pwd.pwd else { return false }
            view.pwd = String(cString: p)
            window.metadataChanged()
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view else { return false }
            let n = a.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            window.notify(view, text: [title, body].filter { !$0.isEmpty }.joined(separator: ": "))
        case GHOSTTY_ACTION_RING_BELL:
            guard let view else { return false }
            window.notify(view, text: nil)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursor(a.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view else { return false }
            let link = a.mouse_over_link
            view.pane?.hoveredLink = link.len > 0 && link.url != nil
                ? String(data: Data(bytes: link.url, count: link.len), encoding: .utf8) : nil
        case GHOSTTY_ACTION_OPEN_URL:
            guard let ptr = a.open_url.url else { return false }
            let data = Data(bytes: ptr, count: Int(a.open_url.len))
            guard let s = String(data: data, encoding: .utf8), let url = URL(string: s) else { return false }
            NSWorkspace.shared.open(url)
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            window.window?.toggleFullScreen(nil)
        case GHOSTTY_ACTION_OPEN_CONFIG:
            SettingsWindow.shared.show()
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
        default:
            return false
        }
        return true
    }

    // MARK: Clipboard (text/plain only; images and other MIME types are not served)

    private static func readClipboard(
        _ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?,
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ n: Int, _ list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard loc == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = SurfaceView.from(ud)?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let wantsText = (0..<n).contains { i in mimes?[i].map { String(cString: $0) } == "text/plain" }
        let text = wantsText ? NSPasteboard.general.string(forType: .string) : nil
        if text == nil && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, text: text, available: list && NSPasteboard.general.string(forType: .string) != nil,
                 state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func confirmClipboard(
        _ ud: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
    ) {
        guard let view = SurfaceView.from(ud), view.surface != nil else { return }
        // Copy the borrowed text now; the alert runs after this callback returns.
        var text: String?
        if let c = confirm?.pointee, let contents = c.contents {
            for i in 0..<c.contents_len where String(cString: contents[i].mime) == "text/plain" {
                text = String(data: Data(bytes: contents[i].data, count: contents[i].len), encoding: .utf8)
            }
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
                ? "Paste text that may run commands?" : "A program wants to read your clipboard."
            alert.informativeText = String((text ?? "").prefix(500))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            let allowed = alert.runModal() == .alertFirstButtonReturn
            // The pane may have closed (and its surface been freed) while the alert was up.
            guard let surface = view.surface else { return }
            if allowed {
                complete(surface, text: text, available: false, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    private static func complete(
        _ surface: ghostty_surface_t, text: String?, available: Bool,
        state: UnsafeMutableRawPointer?, confirmed: Bool
    ) {
        let mime = strdup("text/plain")!
        let data = strdup(text ?? "")!
        defer { free(mime); free(data) }
        var content = ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data))
        var avail: UnsafePointer<CChar>? = UnsafePointer(mime)
        withUnsafePointer(to: &content) { cp in
            withUnsafePointer(to: &avail) { ap in
                var c = ghostty_clipboard_complete_s(
                    contents: text == nil ? nil : cp, contents_len: text == nil ? 0 : 1,
                    available: available ? ap : nil, available_len: available ? 1 : 0,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &c, state)
            }
        }
    }

    private static func writeClipboard(
        _ loc: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ n: Int, _ confirm: Bool
    ) {
        guard loc == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        guard let item = (0..<n).map({ content[$0] }).first(where: { String(cString: $0.mime) == "text/plain" }),
              let text = String(data: Data(bytes: item.data, count: item.len), encoding: .utf8) else { return }
        let write = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        guard confirm else { return write() }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "A program wants to write to your clipboard."
            alert.informativeText = String(text.prefix(500))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            if alert.runModal() == .alertFirstButtonReturn { write() }
        }
    }
}
