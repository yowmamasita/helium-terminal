import Darwin
import Foundation

/// A Claude Code or Codex session running in a pane, with what it takes to resume it.
struct AgentSession: Codable, Equatable {
    enum Kind: String, Codable { case claude, codex }

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

    private enum CodingKeys: String, CodingKey { case kind, sessionID, cwd, flags }

    /// Typed into a fresh shell on relaunch, so the agent picks up the same conversation.
    /// Typed into a fresh shell on relaunch, using the template from Settings.
    var resumeCommand: String { resumeCommand(template: Self.template(for: kind)) }

    /// Fills `{id}`, `{flags}` and `{cwd}` (shell-quoted) into a command template.
    func resumeCommand(template: String) -> String {
        var t = template
        // With no flags, take the placeholder's separating space with it instead of leaving a gap.
        if flags.isEmpty { t = t.replacingOccurrences(of: " {flags}", with: "").replacingOccurrences(of: "{flags} ", with: "") }
        let values = ["{id}": Self.shellQuote(sessionID), "{flags}": flags.map(Self.shellQuote).joined(separator: " "),
                      "{cwd}": Self.shellQuote(cwd ?? ".")]
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
        return out + rest
    }

    static func defaultTemplate(for kind: Kind) -> String {
        switch kind {
        case .claude: "claude {flags} --resume {id}"
        case .codex: "codex resume {id} {flags}"
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
            if dropAlone.contains(name) {
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
    /// The outermost Claude Code or Codex process on a pane's tty, if any, as a resumable session.
    static func session(onTTY dev: dev_t, tree: ProcessTree) -> AgentSession? {
        let pids = tree.processes(onTTYs: [dev])
        // By argv[0], not the kernel's process name: native Claude Code runs as a versioned
        // file (…/claude/versions/2.1.295) behind a `claude` symlink.
        var argvs: [pid_t: [String]] = [:]
        for pid in pids { argvs[pid] = arguments(of: pid) }
        func agentKind(_ pid: pid_t) -> AgentSession.Kind? {
            argvs[pid]?.first.flatMap { AgentSession.Kind(rawValue: ($0 as NSString).lastPathComponent) }
        }
        for pid in pids.sorted() {
            guard let kind = agentKind(pid), kind != tree.parent[pid].flatMap(agentKind) else { continue }
            let claude = kind == .claude ? claudeSession(pid: pid) : nil
            let id = kind == .claude ? claude?.id : codexSessionID(pid: pid)
            guard let id, let argv = argvs[pid] else { continue }
            // Only interactive sessions are resumed; `codex exec` and friends also write session logs.
            let nonInteractive: Set<String> = ["exec", "e", "review", "mcp", "mcp-server", "app-server", "login",
                                               "logout", "apply", "a", "sandbox", "debug", "cloud", "completion"]
            if kind == .codex, let sub = codexSubcommand(Array(argv.dropFirst())),
               nonInteractive.contains(sub) { continue }
            if kind == .claude, argv.contains(where: { $0 == "-p" || $0 == "--print" }) { continue }
            return AgentSession(kind: kind, sessionID: id, cwd: Metadata.cwd(of: pid),
                                flags: AgentSession.resumableFlags(kind, Array(argv.dropFirst())),
                                running: claude?.running ?? false, unblockedAt: claude?.unblockedAt)
        }
        return nil
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

    /// Codex keeps its rollout log (~/.codex/sessions/…/rollout-<time>-<uuid>.jsonl) open while running.
    static func codexSessionID(pid: pid_t) -> String? {
        for path in openFiles(of: pid) where path.contains("/.codex/sessions/") && path.hasSuffix(".jsonl") {
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            guard name.hasPrefix("rollout-"), name.count > 36 else { continue }
            let id = String(name.suffix(36))
            if UUID(uuidString: id) != nil { return id }
        }
        return nil
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

    /// argv of a process (KERN_PROCARGS2: argc, exec path, padding, then the arguments).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 } // exec path
        while i < size, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    private static func openFiles(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            paths.append(withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        return paths
    }
}
