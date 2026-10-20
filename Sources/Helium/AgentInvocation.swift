import Foundation

/// The CLI argv, without an interpreter/launcher. No subprocess is needed to inspect it.
struct AgentInvocation {
    let kind: AgentSession.Kind
    let arguments: [String]
    let isLauncher: Bool

    init?(_ argv: [String]) {
        guard let executable = argv.first else { return nil }
        let name = (executable as NSString).lastPathComponent
        if let kind = AgentSession.Kind(rawValue: name) {
            self.kind = kind
            arguments = Array(argv.dropFirst())
            isLauncher = false
        } else if ["bun", "node"].contains(name), argv.count > 1 {
            let script = argv[1]
            let scriptName = (script as NSString).lastPathComponent
            if scriptName == "omp" || script.contains("/@oh-my-pi/pi-coding-agent/") && scriptName == "cli.js" {
                kind = .omp
            } else if scriptName == "opencode" {
                kind = .opencode
            } else { return nil }
            arguments = Array(argv.dropFirst(2))
            isLauncher = kind == .opencode
        } else { return nil }
    }

    var interactive: Bool {
        switch kind {
        case .claude:
            return !arguments.contains { ["-p", "--print", "--help", "--version"].contains($0) }
        case .codex:
            let commands: Set<String> = ["exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin",
                                         "app-server", "remote-control", "app", "completion", "update", "doctor",
                                         "sandbox", "debug", "apply", "a", "queue", "archive", "delete", "migrate-rollouts",
                                         "unarchive", "cloud", "exec-server", "features", "help"]
            return !arguments.contains { ["--help", "-h", "--version", "-V"].contains($0) }
                && !commands.contains(Agents.codexSubcommand(arguments) ?? "")
        case .omp:
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                if argument == "--" { break }
                let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if ["-p", "--print", "--mode", "--export", "--help", "-h", "--version", "--list-models", "--no-session"].contains(name)
                    || argument.hasPrefix("__omp_worker_") { return false }
                if Self.ompValues.contains(name), !argument.contains("=") { i += 1 }
                i += 1
            }
            return true
        case .opencode:
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                if argument == "--" { return true }
                let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if ["--help", "-h", "--version", "-v", "--mini"].contains(name) { return false }
                if !argument.hasPrefix("-") {
                    return !["run", "serve", "web", "acp", "mcp", "auth", "models", "export", "import", "session",
                             "stats", "upgrade", "uninstall", "debug", "db"].contains(argument)
                }
                if (Self.openCodeValues.contains(name) || ["--session", "-s", "--prompt", "--password"].contains(name)),
                   !argument.contains("=") { i += 1 }
                i += 1
            }
            return true
        }
    }

    /// Directory/profile overrides only, never API keys, inline config, or arbitrary environment.
    static let environmentKeys: Set<String> = [
        "HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CONFIG_DIR", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR",
        "OMP_PROFILE", "PI_PROFILE", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "OPENCODE_DB", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_TUI_CONFIG",
    ]

    private static let ompValues: Set<String> = [
        "--cwd", "--config", "--add-dir", "--provider", "--model", "--smol", "--slow", "--plan", "--prewalk-into",
        "--plan-yolo-into", "--max-time", "--service-tier", "--system-prompt", "--system-prompt-template",
        "--append-system-prompt", "--provider-session-id", "--prompt-cache-key", "--session-dir", "--models", "--tools",
        "--thinking", "--hook", "--extension", "-e", "--trusted-extension", "--plugin-dir", "--skills", "--profile", "--alias",
    ]
    private static let ompSwitches: Set<String> = [
        "--no-title", "--no-tools", "--no-lsp", "--no-extensions", "--no-skills", "--no-rules", "--no-prewalk",
        "--no-mcp", "--no-hooks", "--no-plugins", "--verbose", "--yolo", "--plan-yolo", "--offline",
    ]
    private static let openCodeValues: Set<String> = [
        "--model", "-m", "--agent", "--variant", "--port", "--hostname", "--mdns-domain", "--log-level", "--dir",
    ]
    private static let openCodeSwitches: Set<String> = ["--pure", "--print-logs", "--mdns"]

    /// Keep launch configuration, not prompt attachments, one-shot selectors, or plaintext credentials.
    static func resumableFlags(_ kind: AgentSession.Kind, _ args: [String]) -> [String] {
        let values = kind == .omp ? ompValues : openCodeValues
        let switches = kind == .omp ? ompSwitches : openCodeSwitches
        let droppedValues: Set<String> = kind == .omp
            ? ["--resume", "-r", "--restore", "--session", "--fork", "--from-claude", "--from-codex", "--goal", "--api-key"]
            : ["--session", "-s", "--prompt", "--password"]
        var result: [String] = []
        var i = 0
        if kind == .opencode, args.first == "attach", args.count > 1,
           let url = URLComponents(string: args[1]), url.user == nil, url.password == nil {
            result = ["attach", args[1]]
            i = 2
        }
        while i < args.count {
            let argument = args[i]
            if argument == "--" { break }
            let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            i += 1
            if droppedValues.contains(name) {
                if !argument.contains("="), i < args.count, !args[i].hasPrefix("-") { i += 1 }
            } else if values.contains(name) {
                if argument.contains("=") { result.append(argument) }
                else if i < args.count { result += [argument, args[i]]; i += 1 }
            } else if switches.contains(name) { result.append(argument) }
        }
        return result
    }
}
