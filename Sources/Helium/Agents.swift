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
        let t = UserDefaults.standard.string(forKey: templateKey(for: kind))?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? defaultTemplate(for: kind) : t
    }

    /// Whether sessions of this agent are resumed on relaunch (Settings; on by default).
    static func resumeEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(for: kind)) as? Bool ?? true
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+%")
        // A leading "=" is zsh's command-path expansion, so it needs quoting too.
        if !s.isEmpty, !s.hasPrefix("="), s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Drops what must not be replayed: resume/continue options (a new ID is appended) and an
    /// initial prompt (resuming must not send it again). Prompts are recognised as arguments
    /// with spaces, since flag values almost never contain them.
    static func resumableFlags(_ kind: Kind, _ args: [String]) -> [String] {
        let dropWithValue: Set<String> = kind == .claude
            ? ["-r", "--resume", "--session-id", "--from-pr"] : ["resume", "fork"]
        let dropAlone: Set<String> = kind == .claude
            ? ["-c", "--continue", "--fork-session"] : ["--last"]
        // Options whose values often contain spaces; such a value isn't an initial prompt.
        let takesText: Set<String> = kind == .claude
            ? ["--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--system-prompt",
               "--append-system-prompt", "--add-dir", "--mcp-config", "--settings", "--agents", "--model"]
            : ["-c", "--config", "-m", "--model"]
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if dropAlone.contains(name) {
                i += 1
            } else if dropWithValue.contains(name) {
                // The value is optional for `claude -r` (it opens a picker); only skip a value-shaped next arg.
                let next = i + 1 < args.count ? args[i + 1] : nil
                let takesNext = !a.contains("=") && next.map { !$0.hasPrefix("-") && !$0.contains(" ") } == true
                i += takesNext ? 2 : 1
            } else if !a.hasPrefix("-") && a.contains(where: \.isWhitespace), !(i > 0 && takesText.contains(args[i - 1])) {
                i += 1 // initial prompt
            } else {
                out.append(a)
                i += 1
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
            let id: String? = switch kind {
            case .claude: claudeSessionID(pid: pid)
            case .codex: codexSessionID(pids: pids.filter { agentKind($0) == .codex })
            }
            guard let id, let argv = argvs[pid] else { continue }
            // Only interactive sessions are resumed; `codex exec` and friends also write session logs.
            let nonInteractive: Set<String> = ["exec", "e", "review", "mcp", "mcp-server", "app-server", "login",
                                               "logout", "apply", "a", "sandbox", "debug", "cloud", "completion"]
            if kind == .codex, let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
               nonInteractive.contains(sub) { continue }
            if kind == .claude, argv.contains(where: { $0 == "-p" || $0 == "--print" }) { continue }
            return AgentSession(kind: kind, sessionID: id, cwd: Metadata.cwd(of: pid),
                                flags: AgentSession.resumableFlags(kind, Array(argv.dropFirst())))
        }
        return nil
    }

    /// Claude Code records each interactive session in ~/.claude/sessions/<pid>.json (undocumented;
    /// read defensively and ignored if the format changes).
    static func claudeSessionID(pid: pid_t) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["kind"] as? String ?? "interactive" == "interactive",
              (obj["pid"] as? Int).map({ $0 == Int(pid) }) ?? true, // a leftover file from a reused pid
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Codex keeps its rollout log (~/.codex/sessions/…/rollout-<time>-<uuid>.jsonl) open while running.
    static func codexSessionID(pids: [pid_t]) -> String? {
        for pid in pids {
            for path in openFiles(of: pid) where path.contains("/.codex/sessions/") && path.hasSuffix(".jsonl") {
                let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
                guard name.hasPrefix("rollout-"), name.count > 36 else { continue }
                let id = String(name.suffix(36))
                if UUID(uuidString: id) != nil { return id }
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
