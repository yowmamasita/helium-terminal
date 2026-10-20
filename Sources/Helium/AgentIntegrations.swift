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
        if kind == .omp || kind == nil && (installed("omp", home: home, env: env) || FileManager.default.fileExists(atPath: agentRoot.path)) {
            for agent in Set(agentDirectories) where configured.insert("omp:" + agent.path).inserted {
                perform("omp extension") {
                    let source = resourceDirectory.appendingPathComponent("omp-loader.js")
                    let destination = agent.appendingPathComponent("extensions/helium-terminal-session.js")
                    let text = try String(contentsOf: source, encoding: .utf8)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let old = try String(contentsOf: destination, encoding: .utf8)
                        guard old.hasPrefix("// Helium Terminal agent integration.") else { throw SetupError.existingExtension }
                    }
                    try update(destination) { _ in text }
                }
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
