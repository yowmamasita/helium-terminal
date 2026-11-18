import Darwin
import Foundation

/// Agents whose own files say which conversation a process has open. Read-only, no subprocess, nothing installed.
/// One open conversation is taken as is. Several (after /new) are told apart only by that process's own log;
/// otherwise there is no answer rather than a guess.
enum NativeSessions {
    /// GitHub Copilot CLI: `session-state/<id>/inuse.<pid>.hold` is held open for every open session, and the
    /// pid's log (`logs/process-<ms>-<pid>.log`, also held open) records each foreground switch.
    static func copilot(_ process: AgentProcess) -> AgentSession? {
        let pid = process.identity.pid
        guard let files = AgentProcess.openFiles(pid) else { return nil }
        var open: [String: URL] = [:]
        var log: String?
        for (_, path) in files {
            let url = URL(fileURLWithPath: path)
            let directory = url.deletingLastPathComponent()
            if url.lastPathComponent == "inuse.\(pid).hold",
               directory.deletingLastPathComponent().lastPathComponent == "session-state",
               UUID(uuidString: directory.lastPathComponent) != nil {
                open[directory.lastPathComponent] = directory
            } else if url.lastPathComponent.hasPrefix("process-"), url.lastPathComponent.hasSuffix("-\(pid).log") {
                log = path
            }
        }
        let id: String
        if open.count == 1 {
            id = open.keys.first!
        } else {
            guard open.count > 1, let log, let tail = tail(log),
                  let last = lastMatch(in: tail, after: "] Registering foreground session: ", among: Set(open.keys)) else { return nil }
            id = last
        }
        // A resumed session keeps its own folder while the process stays where it started.
        let cwd = (tail(open[id]!.appendingPathComponent("workspace.yaml").path, limit: 16 * 1024)).flatMap(yamlCwd)
        return session(.copilot, id, process, cwd: cwd)
    }

    /// Antigravity CLI: the open conversation's `presence/<id>.lock` is held; with several, the log on fd 1/2 breaks the tie.
    static func agy(_ process: AgentProcess) -> AgentSession? {
        guard let files = AgentProcess.openFiles(process.identity.pid) else { return nil }
        var open = Set<String>()
        var log: String?
        for (fd, path) in files {
            let url = URL(fileURLWithPath: path)
            let directory = url.deletingLastPathComponent()
            if url.pathExtension == "lock", directory.lastPathComponent == "presence",
               directory.deletingLastPathComponent().lastPathComponent == "antigravity-cli" {
                let id = url.deletingPathExtension().lastPathComponent
                if UUID(uuidString: id) != nil { open.insert(id) }
            } else if fd == 2, url.pathExtension == "log" {
                log = path
            }
        }
        let id: String
        if open.count == 1 {
            id = open.first!
        } else {
            guard open.count > 1, let log, let tail = tail(log),
                  let last = lastMatch(in: tail, after: "conversation ", among: open) else { return nil }
            id = last
        }
        return session(.agy, id, process, cwd: nil)
    }

    /// Grok Build: `$GROK_HOME/active_sessions.json` lists `{session_id, pid, cwd, opened_at}` per live session.
    /// After /new one pid holds several; the most recently opened is taken (the dashboard switches without a trace).
    static func grok(_ process: AgentProcess) -> AgentSession? {
        let home = AgentIntegrations.path(process.environment["GROK_HOME"],
                                          relativeTo: URL(fileURLWithPath: process.environment["HOME"] ?? NSHomeDirectory()),
                                          default: ".grok")
        guard let data = tail(home.appendingPathComponent("active_sessions.json").path, limit: 1024 * 1024, whole: true),
              let entries = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [[String: Any]] else { return nil }
        let mine = entries.filter { ($0["pid"] as? Int) == Int(process.identity.pid) }
        guard let newest = mine.max(by: { order($0["opened_at"]) < order($1["opened_at"]) }),
              let id = newest["session_id"] as? String, UUID(uuidString: id) != nil else { return nil }
        // The welcome screen's placeholder session is deleted when unused; resuming it would fail.
        let sessions = home.appendingPathComponent("sessions")
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path))?.contains {
            FileManager.default.fileExists(atPath: sessions.appendingPathComponent($0).appendingPathComponent(id).path)
        } ?? false
        var result = session(.grok, id, process, cwd: newest["cwd"] as? String)
        result?.unpersisted = saved ? nil : true
        return result
    }

    /// Hermes Agent, `--tui` only: the TUI child keeps the active session ID in the file named by its environment.
    /// The default line-mode CLI keeps no per-process record that follows /new or /resume.
    static func hermes(_ process: AgentProcess, tree: ProcessTree) -> AgentSession? {
        for child in tree.children[process.identity.pid] ?? [] {
            guard let file = AgentProcess.arguments(child)?.hermesSessionFile, file.hasPrefix("/"),
                  URL(fileURLWithPath: file).lastPathComponent.hasPrefix("hermes-tui-active-session-"),
                  let text = tail(file, limit: 4096, whole: true),
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let id = object["session_id"] as? String, validHermesID(id) else { continue }
            return session(.hermes, id, process, cwd: nil)
        }
        return nil
    }

    /// `YYYYMMDD_HHMMSS_<6 hex>`.
    static func validHermesID(_ id: String) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 8 && parts[1].count == 6 && parts[2].count == 6
            && parts[0].allSatisfy(\.isASCII) && parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isASCII)
            && parts[1].allSatisfy(\.isNumber) && parts[2].allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func session(_ kind: AgentSession.Kind, _ id: String, _ process: AgentProcess, cwd: String?) -> AgentSession? {
        let cwd = cwd.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
        return AgentSession(kind: kind, sessionID: id, cwd: cwd ?? Metadata.cwd(of: process.identity.pid),
                            flags: AgentSession.resumableFlags(kind, process.invocation.arguments),
                            environment: process.environment.isEmpty ? nil : process.environment, command: process.command)
    }

    /// The ID (from `among`) following the last occurrence of `marker`, so a later line always wins.
    static func lastMatch(in text: String, after marker: String, among ids: Set<String>) -> String? {
        var best: (position: String.Index, id: String)?
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: marker, range: search) {
            let candidate = String(text[range.upperBound...].prefix(36))
            if ids.contains(candidate) { best = (range.lowerBound, candidate) }
            search = range.upperBound..<text.endIndex
        }
        return best?.id
    }

    static func yamlCwd(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("cwd:") {
            var value = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
                if value.contains("\\") || q == "'" && value.contains("'") { return nil } // escaped forms: not worth guessing
            }
            return value
        }
        return nil
    }

    private static func order(_ value: Any?) -> String {
        if let n = value as? NSNumber { return String(format: "%020.3f", n.doubleValue) }
        return value as? String ?? ""
    }

    /// The last `limit` bytes of a file (all of it when `whole` and it fits), without reading the rest.
    static func tail(_ path: String, limit: Int = 256 * 1024, whole: Bool = false) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if whole, size > UInt64(limit) { return nil }
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
