import Foundation

/// Fallback for omp launches with extensions disabled. The breadcrumb tracks /new and /resume.
enum OmpSessions {
    static func session(process: AgentProcess, ttyName: String) -> AgentSession? {
        let env = process.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let base = AgentIntegrations.path(env["PI_CONFIG_DIR"], relativeTo: home, default: ".omp")
        let profile = option("--profile", in: process.invocation.arguments) ?? env["OMP_PROFILE"] ?? env["PI_PROFILE"]
        let named = profile.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        let standard = (named.map { base.appendingPathComponent("profiles/\($0)") } ?? base).appendingPathComponent("agent")
        var directory = named == nil
            ? AgentIntegrations.path(env["PI_CODING_AGENT_DIR"], relativeTo: home, default: standard.path) : standard
        if directory.standardizedFileURL == standard.standardizedFileURL, let xdg = env["XDG_STATE_HOME"] {
            let app = URL(fileURLWithPath: xdg).appendingPathComponent(named.map { "omp/profiles/\($0)" } ?? "omp")
            if FileManager.default.fileExists(atPath: app.path) { directory = app }
        }
        let tty = ttyName.hasPrefix("/dev/") ? String(ttyName.dropFirst(5)) : ttyName
        let breadcrumb = directory.appendingPathComponent("terminal-sessions/" + tty.replacingOccurrences(of: "/", with: "-"))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: breadcrumb.path),
              let data = boundedRead(breadcrumb), let pointer = pointer(data) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let started = Double(process.identity.seconds) + Double(process.identity.microseconds) / 1_000_000
        let journal = URL(fileURLWithPath: pointer.file, relativeTo: URL(fileURLWithPath: pointer.cwd, isDirectory: true)).standardizedFileURL
        let header = boundedRead(journal).flatMap(header)
        let launched = option("--resume", in: process.invocation.arguments) ?? option("-r", in: process.invocation.arguments)
            ?? option("--session", in: process.invocation.arguments) ?? option("--restore", in: process.invocation.arguments)
        // writeIfChangedSync can legitimately leave an older mtime when explicitly resuming
        // the same file on the same tty. Otherwise an older breadcrumb is stale tty metadata.
        let sameLaunch = launched.map { $0 == journal.path || $0 == header?.id } ?? false
        guard modified >= started || sameLaunch else { return nil }
        let id: String
        let unpersisted: Bool
        if let header { id = header.id; unpersisted = false }
        else {
            let stem = journal.deletingPathExtension().lastPathComponent
            guard pointer.fresh, journal.pathExtension == "jsonl", let suffix = stem.split(separator: "_").last,
                  UUID(uuidString: String(suffix)) != nil else { return nil }
            id = String(suffix)
            unpersisted = true
        }
        return AgentSession(kind: .omp, sessionID: id, cwd: pointer.cwd,
                            flags: AgentSession.resumableFlags(.omp, process.invocation.arguments), sessionFile: journal.path,
                            environment: env.isEmpty ? nil : env, unpersisted: unpersisted ? true : nil,
                            command: process.command)
    }

    static func pointer(_ data: Data) -> (cwd: String, file: String, fresh: Bool)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].hasPrefix("/"), !lines[1].isEmpty,
              !lines[0].utf8.contains(0), !lines[1].utf8.contains(0) else { return nil }
        return (lines[0], lines[1], lines.dropFirst(2).contains("fresh"))
    }

    static func header(_ data: Data) -> (id: String, cwd: String?)? {
        for line in data.split(separator: 10, maxSplits: 3).prefix(3) {
            guard let value = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  value["type"] as? String == "session", let id = value["id"] as? String,
                  UUID(uuidString: id) != nil else { continue }
            return (id, value["cwd"] as? String)
        }
        return nil
    }

    private static func boundedRead(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 64 * 1024)
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == name, index + 1 < args.count, !args[index + 1].hasPrefix("-") { return args[index + 1] }
            if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
        }
        return nil
    }
}
