import AppKit
import GhosttyKit

// `helium <command> ...` talks to the running app over its socket and exits
// without touching AppKit or libghostty, so CLI calls stay cheap.
let args = Array(CommandLine.arguments.dropFirst())
// `+action` runs a libghostty CLI action (e.g. `+show-config --docs`, `+list-fonts`).
if let first = args.first, first.hasPrefix("+") {
    _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
    ghostty_cli_try_action() // exits when it ran an action
    exit(1)
}
if let first = args.first, !first.hasPrefix("-") {
    exit(CLI.run(args))
}
// `helium` typed in a shell opens the app instead of running it in the foreground.
// LaunchServices starts the app with stdin on /dev/null, so this never fires for it.
if args.isEmpty, isatty(STDIN_FILENO) != 0 {
    // Via a symlink (/opt/homebrew/bin/helium), resolve to .app/Contents/MacOS/helium-terminal first.
    let app = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else {
        FileHandle.standardError.write("helium: not inside an app bundle\n".data(using: .utf8)!)
        exit(1)
    }
    NSWorkspace.shared.open(app)
    exit(0)
}

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    FileHandle.standardError.write("helium: ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
