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
if let first = args.first, (!first.hasPrefix("-") || ["--help", "-h"].contains(first)) {
    exit(CLI.run(args))
}
// `helium` typed in a shell opens the app instead of running it in the foreground.
// LaunchServices starts the app with stdin on /dev/null, so this never fires for it.
let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
if args.isEmpty, isatty(STDIN_FILENO) != 0 {
    // Via a symlink (/opt/homebrew/bin/helium), resolve to .app/Contents/MacOS/helium-terminal first.
    guard let app = Launch.appBundle(containing: executable) else {
        FileHandle.standardError.write("helium: not inside an app bundle\n".data(using: .utf8)!)
        exit(1)
    }
    NSWorkspace.shared.open(app)
    exit(0)
}
// Started through the symlink with stdin not a terminal (a script, an agent, launchd), the app would run
// in this process, where Bundle.main is /opt/homebrew/bin: no Info.plist, and the resource bundle lookup
// crashes. Run the real binary in its place so Bundle.main is the app.
if Launch.needsRelaunch(executable: executable, mainBundle: Bundle.main.bundleURL) {
    let real = executable.resolvingSymlinksInPath().path
    var argv = CommandLine.arguments.map { strdup($0) }
    argv[0] = strdup(real)
    execv(real, argv + [nil])
    FileHandle.standardError.write("helium: cannot run \(real): \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
    exit(1)
}

// Panes inherit this environment, and `open` passes on its caller's. Opened from a Claude Code session,
// Claude in every pane would see itself as that session's child and skip ~/.claude/sessions/<pid>.json,
// which session restore reads (issue #1). It would also inherit the parent's messaging token.
// ponytail: the variables Claude Code 2.1.296 sets for its children; extend if a newer version adds more.
for name in ["CLAUDECODE", "AI_AGENT", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_ENTRYPOINT",
             "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
             "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
             "CLAUDE_CODE_MESSAGING_TOKEN"] {
    unsetenv(name)
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
