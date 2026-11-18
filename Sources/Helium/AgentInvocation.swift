import Foundation

/// The CLI argv, without an interpreter/launcher. No subprocess is needed to inspect it.
struct AgentInvocation {
    let kind: AgentSession.Kind
    let arguments: [String]
    let isLauncher: Bool

    /// Node agents that set `process.title` (Pi, Kimi Code) overwrite their argv on macOS:
    /// KERN_PROCARGS2 then reads the title followed by empty strings, and the flags are gone.
    private static let titles: [String: AgentSession.Kind] = ["kimi-code": .kimi]

    init?(_ argv: [String]) {
        guard let executable = argv.first else { return nil }
        let name = (executable as NSString).lastPathComponent
        let rest = Array(argv.dropFirst())
        if let kind = AgentSession.Kind(rawValue: name) ?? Self.titles[name] {
            self.kind = kind
            arguments = rest.allSatisfy(\.isEmpty) ? [] : rest
            isLauncher = false
        } else if ["bun", "node", "nodejs"].contains(name), argv.count > 1 {
            let script = argv[1]
            let scriptName = (script as NSString).lastPathComponent
            if scriptName == "omp" || script.contains("/@oh-my-pi/pi-coding-agent/") && scriptName == "cli.js" {
                kind = .omp
            } else if scriptName == "pi" || (script.contains("/@earendil-works/pi-coding-agent/")
                                             || script.contains("/@mariozechner/pi-coding-agent/")) && scriptName == "cli.js" {
                kind = .pi
            } else if script.contains("/@moonshot-ai/kimi-code/") && scriptName == "main.mjs" {
                kind = .kimi
            } else if scriptName == "opencode" {
                kind = .opencode
            } else if scriptName == "copilot" {
                kind = .copilot // npm's loader; it spawns the native binary, which is the agent.
            } else { return nil }
            arguments = Array(argv.dropFirst(2))
            isLauncher = kind == .opencode || kind == .copilot
        } else if name.hasPrefix("python"), argv.count > 1 {
            // Hermes' own launcher runs `python -I -c '<bootstrap>' args`; pip installs run `python …/bin/hermes args`.
            if argv.count > 3, argv[1] == "-I", argv[2] == "-c", argv[3].contains("from hermes_cli.main import main") {
                arguments = Array(argv.dropFirst(4))
            } else if (argv[1] as NSString).lastPathComponent == "hermes" {
                arguments = Array(argv.dropFirst(2))
            } else { return nil }
            kind = .hermes
            isLauncher = false
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
        case .omp, .pi:
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                if argument == "--" { break }
                let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if ["-p", "--print", "--mode", "--export", "--help", "-h", "--version", "--list-models", "--no-session"].contains(name)
                    || kind == .pi && name == "-v" || argument.hasPrefix("__omp_worker_") { return false }
                if kind == .pi, i == 0, ["install", "remove", "uninstall", "update", "list", "config", "auth", "mcp"].contains(argument) {
                    return false
                }
                if Self.replay[kind]!.values.contains(name), !argument.contains("=") { i += 1 }
                i += 1
            }
            return true
        case .opencode:
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                if argument == "--" { return true }
                let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if ["--help", "-h", "--version", "-v", "--mini", "--completions", "--wizard"].contains(name) { return false }
                if !argument.hasPrefix("-") {
                    // `mini` (V2) loads no plugins, so its conversation can't be tracked.
                    return !["run", "serve", "web", "acp", "mcp", "auth", "models", "export", "import", "session",
                             "stats", "upgrade", "uninstall", "debug", "db", "api", "plugin", "service", "reload",
                             "pair", "update", "mini"].contains(argument)
                }
                if (Self.replay[.opencode]!.values.contains(name) || ["--session", "-s", "--prompt", "--password"].contains(name)),
                   !argument.contains("=") { i += 1 }
                i += 1
            }
            return true
        case .kimi:
            return true // Its argv is blank once the title is set; only the TUI's SessionStart hook reports.
        case .copilot:
            if arguments.contains(where: { ["-p", "--prompt", "--acp", "-h", "--help", "-v", "--version",
                                            "--binary-version", "--connect"].contains(Self.name($0, kind)) }) { return false }
            guard let command = Self.firstPositional(arguments, kind) else { return true }
            return !command.hasSuffix("extension_bootstrap.mjs")
                && !["app", "login", "help", "init", "config", "update", "version", "workflow", "sessions", "memories",
                     "plugin", "mcp", "skill", "instruction", "lsp", "sandbox", "completion"].contains(command)
        case .agy:
            // Go flag parsing stops at the first positional, which is always a subcommand (`agentapi`, `acp`, …).
            return !arguments.contains { ["--print", "--prompt", "--help", "--version"].contains(Self.name($0, kind)) || $0 == "-p" || $0 == "-h" }
                && Self.firstPositional(arguments, kind) == nil
        case .grok:
            if arguments.contains(where: { ["-p", "--single", "--prompt-file", "--prompt-json", "-h", "--help", "-v", "-V",
                                            "--version"].contains(Self.name($0, kind)) }) { return false }
            let command = Self.firstPositional(arguments, kind)
            return command == nil || command == "dashboard" || !Self.grokCommands.contains(command!)
        case .hermes:
            if arguments.contains(where: { ["-z", "--oneshot", "-Q", "-V", "--version", "-h", "--help"].contains(Self.name($0, kind)) }) {
                return false
            }
            let command = Self.firstPositional(arguments, kind)
            return command == nil || command == "chat"
        }
    }

    private static let grokCommands: Set<String> = [
        "agent", "clone", "completions", "doctor", "du", "disk-usage", "export", "help", "inspect", "leader", "login",
        "logout", "mcp", "memory", "models", "plugin", "sessions", "setup", "trace", "update", "usage", "version", "v",
        "worker", "worktree", "wrap",
    ]

    /// Directory/profile overrides only, never API keys, inline config, or arbitrary environment.
    static let environmentKeys: Set<String> = [
        "HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CONFIG_DIR", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR",
        "OMP_PROFILE", "PI_PROFILE", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "OPENCODE_DB", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_TUI_CONFIG",
        "KIMI_CODE_HOME", "COPILOT_HOME", "GROK_HOME", "HERMES_HOME", "HERMES_DATA_DIR_SUFFIX",
    ]

    /// Flags kept on resume, per agent. Everything else (resume selectors, prompts, keys, one-shot options) is dropped.
    private struct Replay {
        var values: Set<String> = []
        var switches: Set<String> = []
        /// Take the next token only when it isn't an option.
        var optional: Set<String> = []
        /// Take tokens until the next option.
        var variadic: Set<String> = []
        /// Dropped together with their value, so the value isn't mistaken for a flag.
        var dropped: Set<String> = []
    }

    private static let replay: [AgentSession.Kind: Replay] = [
        .omp: Replay(
            values: ["--cwd", "--config", "--add-dir", "--provider", "--model", "--smol", "--slow", "--plan", "--prewalk-into",
                     "--plan-yolo-into", "--max-time", "--service-tier", "--system-prompt", "--system-prompt-template",
                     "--append-system-prompt", "--provider-session-id", "--prompt-cache-key", "--session-dir", "--models", "--tools",
                     "--thinking", "--hook", "--extension", "-e", "--trusted-extension", "--plugin-dir", "--skills", "--profile", "--alias"],
            switches: ["--no-title", "--no-tools", "--no-lsp", "--no-extensions", "--no-skills", "--no-rules", "--no-prewalk",
                       "--no-mcp", "--no-hooks", "--no-plugins", "--verbose", "--yolo", "--plan-yolo", "--offline"],
            dropped: ["--resume", "-r", "--restore", "--session", "--fork", "--from-claude", "--from-codex", "--goal", "--api-key"]),
        .pi: Replay(
            values: ["--provider", "--model", "--thinking", "--models", "--tools", "-t", "--exclude-tools", "-xt", "--extension", "-e",
                     "--skill", "--prompt-template", "--theme", "--use-theme", "--tui-mode", "--session-dir", "--system-prompt",
                     "--append-system-prompt"],
            switches: ["--no-tools", "--no-builtin-tools", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates",
                       "--no-themes", "--no-context-files", "--approve", "-a", "--no-approve", "-na", "--offline", "--verbose"],
            dropped: ["--resume", "-r", "--session", "--session-id", "--fork", "--name", "-n", "--api-key", "--export", "--mode"]),
        .opencode: Replay(
            values: ["--model", "-m", "--agent", "--variant", "--port", "--hostname", "--mdns-domain", "--log-level", "--dir", "--server"],
            switches: ["--pure", "--print-logs", "--mdns", "--standalone", "--auto", "--yolo", "--dangerously-skip-permissions"],
            dropped: ["--session", "-s", "--prompt", "--password"]),
        .copilot: Replay(
            values: ["--model", "--mode", "--agent", "--add-dir", "--reasoning-effort", "--context", "--auto-tier", "--plugin-dir",
                     "--disable-mcp-server", "--enable-mcp-server", "--log-level", "--log-dir", "--stream"],
            switches: ["--plan", "--autopilot", "--allow-all", "--allow-all-tools", "--allow-all-paths", "--allow-all-urls", "--yolo",
                       "--no-auto-update", "--disable-builtin-mcps", "--no-custom-instructions", "--no-ask-user", "--experimental",
                       "--no-experimental", "--screen-reader", "--no-mouse", "--no-color", "--banner", "--no-bash-env",
                       "--disallow-temp-dir"],
            optional: ["--mouse", "--bash-env"],
            variadic: ["--allow-tool", "--deny-tool", "--allow-url", "--deny-url", "--available-tools", "--excluded-tools",
                       "--secret-env-vars"],
            dropped: ["--resume", "-r", "--session-id", "--name", "-n", "--interactive", "-i", "--prompt", "-p", "--connect",
                      "--additional-mcp-config", "--attachment", "--share"]),
        .agy: Replay(
            values: ["--model", "--mode", "--effort", "--agent", "--add-dir", "--project"],
            switches: ["--sandbox", "--dangerously-skip-permissions", "--remote-agent"],
            dropped: ["--conversation", "--prompt-interactive", "-i", "--settings", "--log-file"]),
        .grok: Replay(
            values: ["-m", "--model", "--reasoning-effort", "--effort", "--permission-mode", "--sandbox", "--add-dir", "--agent",
                     "--tools", "--disallowed-tools", "--disallowedTools", "--allow", "--allowedTools", "--allowed-tools", "--deny",
                     "--rules", "--append-system-prompt"],
            switches: ["--always-approve", "--yolo", "--no-plan", "--no-subagents", "--disable-web-search", "--minimal",
                       "--fullscreen", "--no-alt-screen", "--leader", "--no-leader"],
            dropped: ["--session-id", "-s", "--load", "--cwd", "--worktree-ref", "--ref", "--system-prompt-override",
                      "--system-prompt", "--agents", "--json-schema"]),
        // A Hermes resume whose policy flags (model, provider, toolsets…) differ from the session's is refused.
        .hermes: Replay(values: ["-p", "--profile"], switches: ["--tui", "--cli", "--native"],
                        dropped: ["--resume", "-r", "-c", "--continue", "--in", "-m", "--model", "--provider", "--reasoning",
                                  "-t", "--toolsets", "-s", "--skills"]),
    ]

    /// Go's flag package (agy) treats `-model` like `--model`.
    private static func name(_ argument: String, _ kind: AgentSession.Kind) -> String {
        let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
        if kind == .agy, name.count > 2, name.hasPrefix("-"), !name.hasPrefix("--") { return "-" + name }
        return name
    }

    /// The first argument that isn't an option or an option's value, or nil before `--`.
    private static func firstPositional(_ args: [String], _ kind: AgentSession.Kind) -> String? {
        let r = replay[kind] ?? Replay()
        var i = 0
        while i < args.count {
            let argument = args[i]
            if argument == "--" { return nil }
            guard argument.hasPrefix("-") else { return argument }
            let name = name(argument, kind)
            i += 1
            guard !argument.contains("=") else { continue }
            if r.values.contains(name) { i += 1 }
            else if r.dropped.contains(name) { if i < args.count, !args[i].hasPrefix("-") { i += 1 } }
            else if r.optional.contains(name) || r.variadic.contains(name) {
                while i < args.count, !args[i].hasPrefix("-") { i += 1 }
            }
        }
        return nil
    }

    private static func withoutCredentials(_ url: String) -> Bool {
        URLComponents(string: url).map { $0.user == nil && $0.password == nil } ?? false
    }

    /// Keep launch configuration, not prompt attachments, one-shot selectors, or plaintext credentials.
    static func resumableFlags(_ kind: AgentSession.Kind, _ args: [String]) -> [String] {
        guard let r = replay[kind] else { return [] }
        var result: [String] = []
        var i = 0
        if kind == .opencode, args.first == "attach", args.count > 1, withoutCredentials(args[1]) {
            result = ["attach", args[1]]
            i = 2
        }
        while i < args.count {
            let argument = args[i]
            if argument == "--" { break }
            let name = name(argument, kind)
            i += 1
            if r.dropped.contains(name) {
                if !argument.contains("="), i < args.count, !args[i].hasPrefix("-") { i += 1 }
            } else if r.values.contains(name) || r.optional.contains(name) {
                var flag = [argument]
                if !argument.contains("="), i < args.count, r.values.contains(name) || !args[i].hasPrefix("-") {
                    flag.append(args[i])
                    i += 1
                } else if !argument.contains("="), r.values.contains(name) { continue }
                let value = flag.count == 2 ? flag[1] : String(argument.dropFirst(name.count + 1))
                if name == "--server", !withoutCredentials(value) { continue }
                result += flag
            } else if r.variadic.contains(name) {
                result.append(argument)
                guard !argument.contains("=") else { continue }
                while i < args.count, !args[i].hasPrefix("-") { result.append(args[i]); i += 1 }
            } else if r.switches.contains(name) { result.append(argument) }
        }
        return result
    }
}
