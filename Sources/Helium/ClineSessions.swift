import Foundation
import SQLite3

/// Cline CLI 3.x. The first pane runs its session in its own process (a `sessions` row with its pid); later panes run
/// theirs in a shared hub daemon, whose own event log ties each session to the pid of the pane that created it.
/// Hooks can't be used: in the hub they run with the first pane's environment. Both databases are internal and
/// undocumented, so they are read defensively, read-only and off the main thread; any surprise means no answer.
enum ClineSessions {
    struct Found {
        let id: String
        let cwd: String?
        let at: Double
        /// `running` during a turn, `pending` while a tool approval waits for the user, then `idle`.
        var status: String? = nil
    }

    private static let lock = NSLock()
    private static var found: [AgentProcess.Identity: Found] = [:]
    private static var looking = Set<AgentProcess.Identity>()

    /// The last lookup's answer (at most one poll old); starts the next lookup in the background.
    static func session(_ process: AgentProcess) -> AgentSession? {
        lock.lock()
        let cached = found[process.identity]
        let start = looking.insert(process.identity).inserted
        lock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async {
                let result = lookup(process)
                lock.lock()
                found[process.identity] = result
                looking.remove(process.identity)
                if found.count > 64 { found = found.filter { AgentProcess.identity($0.key.pid) == $0.key } }
                lock.unlock()
            }
        }
        guard let cached else { return nil }
        var session = AgentSession(kind: .cline, sessionID: cached.id, cwd: cached.cwd ?? Metadata.cwd(of: process.identity.pid),
                                   flags: AgentSession.resumableFlags(.cline, process.invocation.arguments),
                                   environment: process.environment.isEmpty ? nil : process.environment, command: process.command)
        session.running = cached.status == "running"
        session.blocked = cached.status == "pending"
        return session
    }

    static func lookup(_ process: AgentProcess) -> Found? {
        let env = process.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
        var root = AgentIntegrations.path(env["CLINE_DIR"], relativeTo: home, default: ".cline")
        if let i = process.invocation.arguments.firstIndex(of: "--config"), i + 1 < process.invocation.arguments.count {
            root = AgentIntegrations.path(process.invocation.arguments[i + 1], relativeTo: home, default: ".cline")
        }
        let data = AgentIntegrations.path(env["CLINE_DATA_DIR"], relativeTo: home, default: root.appendingPathComponent("data").path)
        let db = AgentIntegrations.path(env["CLINE_DB_DATA_DIR"], relativeTo: home, default: data.appendingPathComponent("db").path)
        let started = Double(process.identity.seconds) + Double(process.identity.microseconds) / 1_000_000
        var best = inProcess(db.appendingPathComponent("sessions.db"), pid: process.identity.pid, since: started)
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: db.path))?
            .filter { $0.hasPrefix("hub-events-") && $0.hasSuffix(".db") } ?? []
        for name in logs {
            if let hub = hubCreated(db.appendingPathComponent(name), pid: process.identity.pid, since: started),
               hub.at > best?.at ?? 0 { best = hub }
        }
        // The hub writes the same row for the sessions it hosts.
        if let id = best?.id { best?.status = status(db.appendingPathComponent("sessions.db"), id: id) }
        return best
    }

    /// `<13-digit ms>_<5 of [0-9a-z]>`.
    static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 13 && parts[0].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[1].count == 5 && parts[1].allSatisfy { $0.isASCII && ($0.isNumber || $0.isLowercase) }
    }

    static func inProcess(_ url: URL, pid: pid_t, since: Double) -> Found? {
        query(url, """
            SELECT session_id, cwd, started_at FROM sessions
            WHERE pid = ?1 AND is_subagent = 0 AND interactive = 1 ORDER BY started_at DESC LIMIT 1
            """, pid: pid, since: nil) { row in
            guard let started = row.text(2).flatMap(iso.date(from:))?.timeIntervalSince1970, started >= since - 1 else { return nil }
            return (row.text(0), row.text(1), started)
        }
    }

    /// The newest `session.created` by a `cli` client that registered with this pid since the process started.
    static func hubCreated(_ url: URL, pid: pid_t, since: Double) -> Found? {
        query(url, """
            SELECT session_id, json_extract(envelope_json, '$.payload.session.cwd'), created_at FROM hub_events
            WHERE event = 'session.created' AND created_at >= ?2
              AND json_extract(envelope_json, '$.payload.session.createdByClientId') IN (
                SELECT json_extract(envelope_json, '$.payload.clientId') FROM hub_events
                WHERE event = 'hub.client.registered' AND created_at >= ?2
                  AND json_extract(envelope_json, '$.payload.clientType') = 'cli'
                  AND json_extract(envelope_json, '$.payload.metadata.pid') = ?1)
            ORDER BY sequence DESC LIMIT 1
            """, pid: pid, since: Int64((since - 1) * 1000)) { row in
            (row.text(0), row.text(1), Double(row.int(2)) / 1000)
        }
    }

    static func status(_ url: URL, id: String) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 40)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT status FROM sessions WHERE session_id = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    }

    private static func query(_ url: URL, _ sql: String, pid: pid_t, since: Int64?,
                              _ read: (Row) -> (String?, String?, Double)?) -> Found? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 40)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(pid))
        if let since { sqlite3_bind_int64(statement, 2, since) }
        guard sqlite3_step(statement) == SQLITE_ROW, let (id, cwd, at) = read(Row(statement: statement)),
              let id, validID(id) else { return nil }
        return Found(id: id, cwd: cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }, at: at)
    }
}
