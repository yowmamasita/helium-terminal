import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController!
    private var server: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        guard Ghostty.shared.start() else {
            let alert = NSAlert()
            alert.messageText = "libghostty failed to start"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        controller = MainWindowController()
        Ghostty.shared.window = controller
        controller.newWorkspace()
        controller.showWindow(nil)

        server = SocketServer { [weak self] req in self?.handle(req) ?? ["ok": false] }
        do { try server?.start() } catch { NSLog("helium: socket API unavailable: \(error)") }
    }

    func applicationDidBecomeActive(_ notification: Notification) { Ghostty.shared.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { Ghostty.shared.setFocus(false) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller?.window?.isVisible == true, Ghostty.shared.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Helium?"
        alert.informativeText = "Processes are still running."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // Cmd+Q, Cmd+H and friends; terminal keybinds come from the Ghostty config.
    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Helium", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Helium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu
        return main
    }

    // MARK: Socket API

    private func handle(_ req: [String: Any]) -> [String: Any] {
        guard let c = controller else { return ["ok": false, "error": "not ready"] }
        let arg = req["arg"] as? String
        func int(_ k: String) -> Int? { (req[k] as? String).flatMap { Int($0) } ?? req[k] as? Int }
        let target = int("pane").flatMap(c.pane(id:)) ?? c.selected?.focusedPane

        switch req["cmd"] as? String {
        case "list":
            return ["ok": true, "tabs": c.workspaces.enumerated().map { i, ws in
                [
                    "id": ws.id, "index": i + 1, "title": ws.title, "cwd": ws.cwd ?? NSNull(),
                    "branch": ws.branch ?? NSNull(), "ports": ws.ports, "notification": ws.notification ?? NSNull(),
                    "unread": ws.unread, "selected": ws === c.selected,
                    "panes": ws.panes.map { p in
                        ["id": p.surface.id, "title": p.surface.title, "cwd": p.surface.pwd ?? NSNull(),
                         "focused": p === ws.focusedPane, "ringing": p.ringing] as [String: Any]
                    },
                ] as [String: Any]
            }]
        case "new-tab":
            guard let ws = c.newWorkspace(inheriting: nil, cwd: req["cwd"] as? String, command: req["command"] as? String)
            else { return ["ok": false, "error": "could not create tab"] }
            return ["ok": true, "tab": ws.id, "pane": ws.panes.first?.surface.id ?? 0]
        case "select":
            guard let id = arg.flatMap(Int.init), let ws = c.workspaces.first(where: { $0.id == id })
            else { return ["ok": false, "error": "no such tab"] }
            c.select(ws)
        case "split":
            guard let p = target else { return ["ok": false, "error": "no pane"] }
            let before = Set(p.workspace?.panes.map(\.surface.id) ?? [])
            c.split(p.surface, arg == "down" ? GHOSTTY_SPLIT_DIRECTION_DOWN : GHOSTTY_SPLIT_DIRECTION_RIGHT)
            let new = p.workspace?.panes.first { !before.contains($0.surface.id) }
            return ["ok": true, "pane": new?.surface.id ?? 0]
        case "focus":
            guard let id = arg.flatMap(Int.init), let p = c.pane(id: id), let ws = p.workspace
            else { return ["ok": false, "error": "no such pane"] }
            ws.focused = p
            c.select(ws)
        case "send":
            guard let p = target, let arg else { return ["ok": false, "error": "need a pane and text"] }
            p.surface.type(arg)
        case "notify":
            guard let p = target else { return ["ok": false, "error": "no pane"] }
            let text = [req["title"] as? String, arg].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            c.notify(p.surface, text: text)
        case "close":
            guard let p = target else { return ["ok": false, "error": "no pane"] }
            c.requestClose(p.surface, processAlive: false)
        default:
            return ["ok": false, "error": "unknown command; run `helium help`"]
        }
        return ["ok": true]
    }
}
