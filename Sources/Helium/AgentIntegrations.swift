import Darwin
import Foundation

/// Small, Helium-gated adapters. No session daemon, dependency installation, or polling process.
enum AgentIntegrations {
    private(set) static var errors: [String] = []

    static var resourceDirectory: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("helium-terminal_helium-terminal.bundle")
        let resources = bundled.flatMap { Bundle(url: $0) } ?? Bundle.module
        return resources.resourceURL!.appendingPathComponent("agent-integration", isDirectory: true)
    }

    private static let runtimeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("helium-agents-\(getpid())-\(UUID().uuidString)", isDirectory: true)

    static func makePaneDirectory(_ id: Int) -> URL? {
        let url = runtimeDirectory.appendingPathComponent(String(id), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return url
        } catch {
            NSLog("helium: cannot create agent metadata directory: %@", error.localizedDescription)
            return nil
        }
    }

    static func removeRuntimeDirectory() { try? FileManager.default.removeItem(at: runtimeDirectory) }

    static func install(restoring state: SessionState? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment) {
        errors.removeAll()
        configured.removeAll()
        install(environment, only: nil)
        func restore(_ node: SessionState.Node) {
            switch node {
            case let .pane(_, agent):
                guard let agent, AgentSession.resumeEnabled(agent.kind) else { return }
                var env = environment
                for (key, value) in agent.environment ?? [:] where AgentInvocation.environmentKeys.contains(key) { env[key] = value }
                install(env, only: agent.kind)
            case let .split(_, _, first, second):
                restore(first)
                restore(second)
            }
        }
        state?.tabs.forEach(restore)
    }

    private static var configured = Set<String>()

    private static func install(_ env: [String: String], only kind: AgentSession.Kind?) {
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let ompRoot = path(env["PI_CONFIG_DIR"], relativeTo: home, default: ".omp")
        let agentRoot = path(env["PI_CODING_AGENT_DIR"], relativeTo: home, default: ompRoot.appendingPathComponent("agent").path)
        var agentDirectories = [agentRoot]
        let profiles = ompRoot.appendingPathComponent("profiles", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey]) {
            agentDirectories += names.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.appendingPathComponent("agent", isDirectory: true) }
        }
        var loaderDirectories = Set<URL>()
        if kind == .omp || kind == nil && (installed("omp", home: home, env: env) || FileManager.default.fileExists(atPath: agentRoot.path)) {
            loaderDirectories.formUnion(agentDirectories)
        }
        // Pi reads the same PI_CODING_AGENT_DIR, defaulting to ~/.pi/agent. The loader serves both hosts.
        let piRoot = path(env["PI_CODING_AGENT_DIR"], relativeTo: home, default: ".pi/agent")
        if kind == .pi || kind == nil && (installed("pi", home: home, env: env) || FileManager.default.fileExists(atPath: piRoot.path)) {
            loaderDirectories.insert(piRoot)
        }
        for agent in loaderDirectories where configured.insert("omp:" + agent.path).inserted {
            perform("omp/Pi extension") {
                try installLoader("omp-loader.js", at: agent.appendingPathComponent("extensions/helium-terminal-session.js"))
            }
        }
        let configHome = path(env["XDG_CONFIG_HOME"], relativeTo: home, default: home.appendingPathComponent(".config").path)
        let openCodeConfig = configHome.appendingPathComponent("opencode", isDirectory: true)
        if (kind == .opencode || kind == nil && (installed("opencode", home: home, env: env) || FileManager.default.fileExists(atPath: openCodeConfig.path))),
           configured.insert("opencode:" + openCodeConfig.path).inserted {
            let json = openCodeConfig.appendingPathComponent("tui.json")
            let jsonc = openCodeConfig.appendingPathComponent("tui.jsonc")
            // Prefer a new sibling layer. OpenCode merges plugin origins without replacing user plugins.
            let destination = !FileManager.default.fileExists(atPath: json.path) ? json : jsonc
            perform("OpenCode TUI plugin") {
                let plugin = resourceDirectory.appendingPathComponent("opencode.mjs").absoluteString
                for existing in [json, jsonc] {
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: existing.path),
                          (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1024 * 1024,
                          let text = try? String(contentsOf: existing, encoding: .utf8) else { continue }
                    if (try? AgentConfig.addingOpenCodePlugin(text, plugin: plugin)) == text { return }
                }
                try update(destination) {
                    try AgentConfig.addingOpenCodePlugin($0, plugin: plugin)
                }
            }
            // V2 ignores V1's plugin list but loads every directory in plugins/; V1 ignores directories there.
            // Never create V2's cli.json: its first run migrates tui.json only when cli.json is missing.
            perform("OpenCode V2 TUI plugin") {
                try installLoader("opencode-v2-loader.mjs",
                                  at: openCodeConfig.appendingPathComponent("plugins/helium-terminal/tui.mjs"))
            }
        }
        // Kimi Code runs SessionStart hooks as `sh -c`; `exec` keeps kimi as the script's parent.
        let kimiHome = path(env["KIMI_CODE_HOME"], relativeTo: home, default: ".kimi-code")
        if (kind == .kimi || kind == nil && FileManager.default.fileExists(atPath: kimiHome.path)),
           configured.insert("kimi:" + kimiHome.path).inserted {
            perform("Kimi Code hook") {
                let script = kimiHome.appendingPathComponent("helium-terminal-hook.sh")
                try installLoader("hook.sh", at: script)
                try update(kimiHome.appendingPathComponent("config.toml")) {
                    try AgentConfig.addingKimiHook($0, command: "exec /bin/sh \(AgentSession.shellQuote(script.path)) kimi",
                                                   marker: "helium-terminal-hook.sh")
                }
            }
        }
        // MiniMax Code's custom status line runs as mcode's own child with the pane's environment (no shell).
        let miniMax = path(env["MINIMAX_DATA_DIR"] ?? env["MAVIS_DATA_DIR"], relativeTo: home, default: ".minimax")
        if (kind == .mcode || kind == nil && (installed("mcode", home: home, env: env) || FileManager.default.fileExists(atPath: miniMax.path))),
           configured.insert("mcode:" + miniMax.path).inserted {
            perform("MiniMax Code status line") {
                let script = miniMax.appendingPathComponent("helium-terminal-hook.sh")
                try installLoader("hook.sh", at: script)
                try update(miniMax.appendingPathComponent("config.yaml")) {
                    try AgentConfig.addingMiniMaxStatusLine($0, command: "/bin/sh \(AgentSession.shellQuote(script.path)) mcode",
                                                            marker: "helium-terminal-hook.sh")
                }
            }
        }
        // ZCode user hooks are off by default; `type: process` runs /bin/sh as zcode's own child. Besides the session,
        // the hooks report working (a prompt or a tool ran), blocked (an approval is shown) and idle (the turn ended).
        let zcode = home.appendingPathComponent(".zcode", isDirectory: true)
        if (kind == .zcode || kind == nil && (installed("zcode", home: home, env: env) || FileManager.default.fileExists(atPath: zcode.path))),
           configured.insert("zcode:" + zcode.path).inserted {
            perform("ZCode hook") {
                let script = zcode.appendingPathComponent("cli/helium-terminal-hook.sh")
                try installLoader("hook.sh", at: script)
                let events = [("SessionStart", nil), ("UserPromptSubmit", "working"), ("PostToolUse", "working"),
                              ("PermissionRequest", "blocked"), ("Stop", "idle")]
                let entries = try events.map { event, state in
                    let entry: [String: Any] = ["hooks": [["type": "process", "command": "/bin/sh",
                                                           "args": [script.path, "zcode"] + (state.map { [$0] } ?? []),
                                                           "timeoutMs": 5000]]]
                    let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
                    return (event: event, entry: String(decoding: data, as: UTF8.self))
                }
                try update(zcode.appendingPathComponent("cli/config.json")) {
                    try AgentConfig.addingZCodeHooks($0, entries, marker: "helium-terminal-hook.sh")
                }
            }
        }
        let codexHome = path(env["CODEX_HOME"], relativeTo: home, default: home.appendingPathComponent(".codex").path)
        if (kind == .codex || kind == nil && (installed("codex", home: home, env: env) || FileManager.default.fileExists(atPath: codexHome.path))),
           configured.insert("codex:" + codexHome.path).inserted {
            let profiles = (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasSuffix(".config.toml") && !$0.hasDirectoryPath } ?? []
            for file in [codexHome.appendingPathComponent("config.toml")] + profiles {
                perform("Codex thread metadata") {
                    try update(file, transform: AgentConfig.addingCodexThreadTitle)
                }
            }
        }
    }

    /// Copies a small loader into an agent's own directory. It finds the rest through the pane's environment,
    /// so no app path is written into user configuration. A foreign file at that path is never replaced.
    private static func installLoader(_ name: String, at destination: URL) throws {
        let text = try String(contentsOf: resourceDirectory.appendingPathComponent(name), encoding: .utf8)
        if FileManager.default.fileExists(atPath: destination.path) {
            let old = try String(contentsOf: destination, encoding: .utf8)
            guard old.prefix(256).contains("Helium Terminal agent integration.") else { throw SetupError.existingExtension }
        }
        try update(destination) { _ in text }
    }

    private static func installed(_ name: String, home: URL, env: [String: String]) -> Bool {
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".bun/bin").path,
               home.appendingPathComponent(".opencode/bin").path]
        return paths.contains { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
    }

    static func path(_ value: String?, relativeTo home: URL, default fallback: String) -> URL {
        let value = (value?.isEmpty == false ? value! : fallback)
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value, relativeTo: home).standardizedFileURL
    }

    private enum SetupError: Error { case existingExtension, oversizedConfig }

    private static func perform(_ name: String, _ body: () throws -> Void) {
        do { try body() }
        catch {
            errors.append("\(name): \(error.localizedDescription)")
            NSLog("helium: agent integration setup failed (%@): %@", name, error.localizedDescription)
        }
    }

    private static func update(_ requested: URL, transform: (String) throws -> String) throws {
        // Dotfile symlinks are common. Change their target, never replace the symlink.
        let url = requested.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes?[.size] as? NSNumber)?.intValue ?? 0 <= 1024 * 1024 else { throw SetupError.oversizedConfig }
        let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        let new = try transform(old)
        guard new != old else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Data(new.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: attributes?[.posixPermissions] ?? 0o600], ofItemAtPath: url.path)
    }
}
