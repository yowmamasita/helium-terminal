import Darwin
import Foundation

/// A running agent's exact conversation and the launch configuration needed to resume it.
struct AgentSession: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case claude, codex, omp, opencode

        var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .omp: "omp (pi harness)"
            case .opencode: "OpenCode"
            }
        }
    }

    var kind: Kind
    var sessionID: String
    /// The agent's working directory; sessions belong to the project they were started in.
    var cwd: String?
    /// The agent's own flags as it was started, minus resume/continue options and an initial prompt.
    var flags: [String]
    /// Claude is in a turn or still has a background shell or monitor going. Polled, not saved.
    var running = false
    /// When Claude's status last moved to something other than "waiting" (blocked on a question or
    /// permission). An answer sent from elsewhere (the phone app) shows up here. Polled, not saved.
    var unblockedAt: Date?
    /// omp resumes the exact journal, not a cwd-dependent session-ID prefix search.
    var sessionFile: String?
    /// Only non-secret configuration/data-location overrides are saved.
    var environment: [String: String]?
    /// No conversation has been persisted or selected. Never silently replace missing saved history.
    var unpersisted: Bool?
    /// The original executable, plus the script for interpreted harnesses. Independent of a new shell's PATH.
    var command: [String]?

    private enum CodingKeys: String, CodingKey { case kind, sessionID, cwd, flags, sessionFile, environment, unpersisted, command }

    /// Typed into a fresh shell on relaunch, using the template from Settings.
    var resumeCommand: String {
        let template = Self.template(for: kind)
        if unpersisted == true, template == Self.defaultTemplate(for: kind) {
            let fresh: Bool
            switch kind {
            case .omp: fresh = sessionFile.map { !FileManager.default.fileExists(atPath: $0) } ?? false
            case .opencode: fresh = true
            case .codex:
                let home = URL(fileURLWithPath: environment?["HOME"] ?? NSHomeDirectory())
                let codexHome = AgentIntegrations.path(environment?["CODEX_HOME"], relativeTo: home, default: ".codex")
                fresh = CodexSessions.hasPersistedSession(sessionID, home: codexHome) == false
            case .claude: fresh = false
            }
            if fresh { return resumeCommand(template: "{command} {flags}") }
        }
        return resumeCommand(template: template)
    }

    /// Fills `{command}`, `{id}`, `{file}`, `{flags}` and `{cwd}` (shell-quoted) into a command template.
    func resumeCommand(template: String) -> String {
        var t = template
        // With no flags, take the placeholder's separating space with it instead of leaving a gap.
        if flags.isEmpty { t = t.replacingOccurrences(of: " {flags}", with: "").replacingOccurrences(of: "{flags} ", with: "") }
        let values = ["{id}": Self.shellQuote(sessionID), "{flags}": flags.map(Self.shellQuote).joined(separator: " "),
                      "{cwd}": Self.shellQuote(cwd ?? "."), "{file}": Self.shellQuote(sessionFile ?? ""),
                      "{command}": (self.command ?? [kind.rawValue]).map(Self.shellQuote).joined(separator: " ")]
        // One pass, so a placeholder inside a substituted value (a flag containing "{cwd}") stays literal.
        var out = ""
        var rest = Substring(t)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            rest = rest[open...]
            if let (key, value) = values.first(where: { rest.hasPrefix($0.key) }) {
                out += value
                rest = rest.dropFirst(key.count)
            } else {
                out += "{"
                rest = rest.dropFirst()
            }
        }
        let command = out + rest
        let overrides = (environment ?? [:]).filter { AgentInvocation.environmentKeys.contains($0.key) }
        guard !overrides.isEmpty else { return command }
        return "export " + overrides.keys.sorted().map { Self.shellQuote("\($0)=\(overrides[$0]!)") }.joined(separator: " ")
            + "; " + command
    }

    static func defaultTemplate(for kind: Kind) -> String {
        switch kind {
        case .claude: "{command} {flags} --resume {id}"
        case .codex: "{command} resume {id} {flags}"
        case .omp: "{command} {flags} --resume {file}"
        case .opencode: "{command} {flags} --session {id}"
        }
    }

    static func templateKey(for kind: Kind) -> String { "ResumeCommand.\(kind.rawValue)" }
    static func enabledKey(for kind: Kind) -> String { "Resume.\(kind.rawValue)" }

    /// The user's template from Settings, or the default when unset or blank.
    static func template(for kind: Kind) -> String {
        let t = HeliumDefaults.standard.string(forKey: templateKey(for: kind))?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? defaultTemplate(for: kind) : t
    }

    /// Whether sessions of this agent are resumed on relaunch (Settings; on by default).
    static func resumeEnabled(_ kind: Kind) -> Bool {
        HeliumDefaults.standard.object(forKey: enabledKey(for: kind)) as? Bool ?? true
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+%")
        // A leading "=" is zsh's command-path expansion, so it needs quoting too.
        if !s.isEmpty, !s.hasPrefix("="), s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// shortcut: these tables mirror the supported current help; update them when agent options change.
    /// Keep these sets in sync with the current Claude help. Variadic options
    /// consume values until the next known option, while optional options consume
    /// one value when present.
    fileprivate static let claudeOptionsWithRequiredValue: Set<String> = [
        "--agent", "--agents", "--append-system-prompt", "--autocompact", "--debug-file",
        "--effort", "--environment", "--fallback-model", "--input-format", "--json-schema",
        "--max-budget-usd", "--model", "-n", "--name", "--output-format", "--permission-mode",
        "--permission-prompts", "--permission-prompt-tool", "--plugin-dir", "--plugin-url",
        "--remote-control-session-name-prefix", "--setting-sources", "--settings", "--system-prompt",
        "--system-prompt-snapshot",
    ]

    fileprivate static let claudeOptionsWithVariadicValue: Set<String> = [
        "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools",
        "--disallowed-tools", "--file", "--mcp-config", "--tools",
    ]

    fileprivate static let claudeOptionsWithOptionalValue: Set<String> = [
        "--cloud", "-d", "--debug", "--prompt-suggestions", "--remote-control", "--teleport", "-w", "--worktree",
    ]

    fileprivate static let claudeKnownOptions: Set<String> =
        claudeOptionsWithRequiredValue
        .union(claudeOptionsWithVariadicValue)
        .union(claudeOptionsWithOptionalValue)
        .union(["--allow-dangerously-skip-permissions", "--ax-screen-reader",
                "--background", "--bg", "--bare", "--brief", "--chrome", "-c", "--continue", "--dangerously-skip-permissions",
                "--desktop", "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections", "--fork-session",
                "--forward-subagent-text", "-h", "--help", "--ide", "--include-hook-events",
                "--include-partial-messages", "--no-chrome", "--no-session-persistence", "-p", "--print",
                "--restricted", "--safe-mode", "--session-id", "--strict-mcp-config", "--tmux", "--verbose",
                "--version", "--replay-user-messages", "--resume", "-r", "--from-pr", "-v"])

    fileprivate static let codexOptionsWithRequiredValue: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
        "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--log-dir", "--color",
    ]

    fileprivate static let codexOptionsWithVariadicValue: Set<String> = ["-i", "--image"]

    static let codexOptionsWithValues: Set<String> =
        codexOptionsWithRequiredValue.union(codexOptionsWithVariadicValue)

    private static let codexKnownOptions: Set<String> = codexOptionsWithValues.union([
        "--oss", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
        "--last", "--no-alt-screen", "--no-daemon", "--search", "--strict-config", "--worktree", "-h", "--help",
        "-V", "--version",
    ])

    fileprivate static func optionName(_ argument: String) -> String {
        String(argument.split(separator: "=", maxSplits: 1).first ?? "")
    }

    fileprivate static func isKnownOption(_ argument: String, _ kind: Kind) -> Bool {
        guard argument.hasPrefix("-") else { return false }
        return (kind == .claude ? claudeKnownOptions : codexKnownOptions).contains(optionName(argument))
    }

    /// Drops what must not be replayed: resume/continue options (a new ID is appended) and an
    /// initial prompt (resuming must not send it again).
    static func resumableFlags(_ kind: Kind, _ args: [String]) -> [String] {
        if kind == .omp || kind == .opencode { return AgentInvocation.resumableFlags(kind, args) }
        let dropWithValue: Set<String> = kind == .claude
            ? ["-r", "--resume", "--session-id", "--from-pr"] : ["resume", "fork"]
        let requiredDropValue = kind == .claude ? ["--session-id"] : []
        let dropAlone: Set<String> = kind == .claude
            ? ["-c", "--continue", "--fork-session"] : ["--last"]
        let requiredValues = kind == .claude ? Self.claudeOptionsWithRequiredValue : Self.codexOptionsWithRequiredValue
        let variadicValues = kind == .claude ? Self.claudeOptionsWithVariadicValue : Self.codexOptionsWithVariadicValue
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { break } // The remaining tokens are the initial prompt.
            let name = Self.optionName(a)
            if kind == .codex, Self.codexOptionsWithVariadicValue.contains(name) {
                i += 1
                if !a.contains("=") {
                    while i < args.count, args[i] != "--", !Self.isKnownOption(args[i], kind) { i += 1 }
                }
            } else if dropAlone.contains(name) {
                i += 1
            } else if dropWithValue.contains(name) {
                i += 1
                if !a.contains("="), i < args.count,
                   requiredDropValue.contains(name) || !Self.isKnownOption(args[i], kind) { i += 1 }
            } else if !a.hasPrefix("-") {
                i += 1 // discard a positional prompt, but keep scanning later option groups
            } else {
                out.append(a)
                i += 1
                guard !a.contains("=") else { continue }
                if requiredValues.contains(name) {
                    if i < args.count { out.append(args[i]); i += 1 }
                } else if variadicValues.contains(name) {
                    while i < args.count, args[i] != "--", !Self.isKnownOption(args[i], kind) {
                        out.append(args[i]); i += 1
                    }
                } else if kind == .claude, claudeOptionsWithOptionalValue.contains(name) {
                    if i < args.count, args[i] != "--", !Self.isKnownOption(args[i], kind) {
                        out.append(args[i]); i += 1
                    }
                }
            }
        }
        return out
    }
}

enum Agents {
    struct Snapshot {
        var process: AgentProcess?
        var session: AgentSession?
        var reported = false
    }

    /// Prefer the foreground agent, not its worker processes or an interpreter's kernel name.
    static func snapshot(onTTY dev: dev_t, tree: ProcessTree, foregroundPID: pid_t,
                         directory: URL?, token: String, ttyName: String) -> Snapshot {
        let pids = tree.processes(onTTYs: [dev])
        var processes: [pid_t: AgentProcess] = [:]
        for pid in pids { processes[pid] = AgentProcess.read(pid) }
        var foregroundAncestors = Set<pid_t>()
        var parent: pid_t? = foregroundPID
        while let pid = parent, pid > 1, foregroundAncestors.insert(pid).inserted { parent = tree.parent[pid] }
        let roots = processes.values.filter { process in
            var parent = tree.parent[process.identity.pid]
            while let pid = parent, pid > 1 {
                if let ancestor = processes[pid], !ancestor.invocation.isLauncher { return false }
                parent = tree.parent[pid]
            }
            return !process.invocation.isLauncher
        }.sorted {
            let a = foregroundAncestors.contains($0.identity.pid)
            let b = foregroundAncestors.contains($1.identity.pid)
            return a != b ? a : $0.identity.pid < $1.identity.pid
        }
        guard let process = roots.first else { return Snapshot() }
        if let directory, let registration = AgentRegistration.load(directory: directory, process: process,
                                                                      token: token, onTTY: dev, tree: tree) {
            return Snapshot(process: process, session: registration.session, reported: true)
        }
        switch process.invocation.kind {
        case .claude:
            guard let metadata = claudeSession(pid: process.identity.pid) else { return Snapshot(process: process) }
            return Snapshot(process: process,
                            session: AgentSession(kind: .claude, sessionID: metadata.id, cwd: Metadata.cwd(of: process.identity.pid),
                                                  flags: AgentSession.resumableFlags(.claude, process.invocation.arguments),
                                                  running: metadata.running, unblockedAt: metadata.unblockedAt,
                                                  environment: process.environment.isEmpty ? nil : process.environment,
                                                  command: process.command))
        case .omp:
            return Snapshot(process: process, session: OmpSessions.session(process: process, ttyName: ttyName))
        case .codex, .opencode:
            return Snapshot(process: process)
        }
    }

    /// Claude Code records each interactive session in ~/.claude/sessions/<pid>.json (undocumented;
    /// read defensively and ignored if the format changes).
    static func claudeSession(pid: pid_t) -> (id: String, running: Bool, unblockedAt: Date?)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        return (try? Data(contentsOf: url)).flatMap { claudeSession($0, pid: pid) }
    }

    /// `running` is a status of "busy" (a turn) or "shell" (idle, with a background shell or monitor),
    /// the two that Claude's own session list counts as live.
    static func claudeSession(_ data: Data, pid: pid_t) -> (id: String, running: Bool, unblockedAt: Date?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["kind"] as? String ?? "interactive" == "interactive",
              (obj["pid"] as? Int).map({ $0 == Int(pid) }) ?? true, // a leftover file from a reused pid
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let status = obj["status"] as? String
        let changed = (obj["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (id, ["busy", "shell"].contains(status), status == "waiting" ? nil : changed)
    }


    /// Finds a Codex subcommand without mistaking a value passed to a global option for one.
    static func codexSubcommand(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { return nil } // The remaining tokens are the interactive prompt.
            guard arg.hasPrefix("-") else { return arg }
            let name = AgentSession.optionName(arg)
            if !arg.contains("="), AgentSession.codexOptionsWithVariadicValue.contains(name) {
                i += 1
                while i < args.count, args[i] != "--", !AgentSession.isKnownOption(args[i], .codex) { i += 1 }
            } else if !arg.contains("="), AgentSession.codexOptionsWithRequiredValue.contains(name) {
                if i + 1 < args.count, args[i + 1] == "--" { return nil }
                i += 2
            } else {
                i += 1
            }
        }
        return nil
    }
}
