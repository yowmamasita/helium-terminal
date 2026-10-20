import Darwin
import Foundation
import SQLite3
import XCTest
@testable import helium_terminal

final class CodexSessionTests: XCTestCase {
    private let first = "550e8400-e29b-41d4-a716-446655440000"
    private let collision = "550e8400-e29b-41d4-a716-4466554fffff"


    func testEmptyThreadStartsFreshButNewlyPersistedOrUnavailableHistoryIsNotReplaced() throws {
        loadIsolatedDefaults()
        try withHome { home in
            let agent = AgentSession(kind: .codex, sessionID: first, cwd: home.path, flags: [],
                                     environment: ["CODEX_HOME": home.path], unpersisted: true,
                                     command: ["/demo/codex"])
            XCTAssertTrue(agent.resumeCommand.hasSuffix("; /demo/codex"))
            let file = home.appendingPathComponent("state_5.sqlite")
            try Data("unavailable metadata".utf8).write(to: file)
            XCTAssertTrue(agent.resumeCommand.hasSuffix("; /demo/codex resume \(first)"))
            try FileManager.default.removeItem(at: file)
            try database(home, rows: [(first, home.path, "/synthetic/current.jsonl")])
            XCTAssertTrue(agent.resumeCommand.hasSuffix("; /demo/codex resume \(first)"))
            var persisted = agent
            persisted.unpersisted = nil
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(persisted.resumeCommand.hasSuffix("; /demo/codex resume \(first)"))
        }
    }
    func testConfiguredTitleParsesTruncatedAndFullIdentity() {
        let prefix = String(first.prefix(29))
        XCTAssertEqual(CodexSessions.prefix(in: "codex | \(prefix)..."), prefix)
        XCTAssertEqual(CodexSessions.prefix(in: "codex | \(first)"), first)
        for spinner in "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" {
            XCTAssertEqual(CodexSessions.prefix(in: "codex | \(prefix)... \(spinner)"), prefix)
            XCTAssertEqual(CodexSessions.prefix(in: "codex | \(first) \(spinner) | project"), first)
        }
    }

    func testBusyAndIdleTitlesKeepTheSameIdentityAndVisibleWorkingIndicator() {
        let prefix = String(first.prefix(29))
        let idle = "codex | \(prefix)... | project"
        let busy = "codex | \(prefix)... ⠋ project"
        let idleID = CodexSessions.prefix(in: idle)
        let busyID = CodexSessions.prefix(in: busy)
        XCTAssertEqual(idleID, prefix)
        XCTAssertEqual(busyID, idleID)
        XCTAssertEqual(CodexSessions.displayTitle(idle, prefix: idleID), "project")
        XCTAssertEqual(CodexSessions.displayTitle(busy, prefix: busyID), "⠋ project")
        let configuredSpinner = "codex | \(prefix)... ⠙ ⠙ project"
        XCTAssertEqual(CodexSessions.displayTitle(configuredSpinner, prefix: CodexSessions.prefix(in: configuredSpinner)), "⠙ project")
        XCTAssertEqual(CodexSessions.prefix(in: "codex | \(first) ⠋ project"), first)
        XCTAssertEqual(CodexSessions.displayTitle("ordinary title", prefix: nil), "ordinary title")
    }

    func testArbitraryTitlesAndMalformedComponentsAreNotIdentities() {
        for title in [first, "project | \(first)", "codex \(first)", " codex | \(first)",
                      "codex | project | \(first)", "codex | \(first) extra", "codex | ⠋",
                      "codex | \(first)...", "codex | \(first.prefix(29))",
                      "codex | 550e8400_e29b-41d4-a716-44665...", "codex | \(first) 🔥"] {
            XCTAssertNil(CodexSessions.prefix(in: title), title)
        }
    }

    func testCustomHomeReturnsOnlyMatchingMetadata() throws {
        try withHome { home in
            try database(home, rows: [(first, "/synthetic/current", "/synthetic/current.jsonl"),
                                      ("650e8400-e29b-41d4-a716-446655440000", "/synthetic/newer", "/synthetic/newer.jsonl")])
            let selected = CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: 0)
            XCTAssertEqual(selected?.sessionID, first)
            XCTAssertEqual(selected?.cwd, "/synthetic/current")
            XCTAssertEqual(selected?.sessionFile, "/synthetic/current.jsonl")
            XCTAssertNil(CodexSessions.resolve(prefix: "750e8400-e29b-41d4-a716-44665", home: home, processPID: 0))
        }
    }

    func testHiddenSuffixCollisionIsRejectedButFullIdentityDisambiguates() throws {
        XCTAssertEqual(first.prefix(29), collision.prefix(29))
        try withHome { home in
            // Reverse insertion order must not influence selection.
            try database(home, rows: [(collision, "/other", "/other.jsonl"), (first, "/first", "/first.jsonl")])
            XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: 0))
            XCTAssertEqual(CodexSessions.resolve(prefix: first, home: home, processPID: 0)?.sessionID, first)
            XCTAssertEqual(CodexSessions.resolve(prefix: collision, home: home, processPID: 0)?.sessionID, collision)
        }
    }

    func testMissingAndIncompatibleMetadataDoNotInventSelection() throws {
        try withHome { home in
            XCTAssertNil(CodexSessions.resolve(prefix: first, home: home, processPID: 0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite").path))
            try Data("not sqlite".utf8).write(to: home.appendingPathComponent("state_5.sqlite"))
            XCTAssertNil(CodexSessions.resolve(prefix: first, home: home, processPID: 0))
        }
    }

    func testMalformedMatchingDatabaseIdentityIsNotAccepted() throws {
        try withHome { home in
            try database(home, rows: [(String(first.prefix(29)) + "a!aaaaa", "/wrong", "/wrong.jsonl")])
            XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: 0))
            XCTAssertNil(CodexSessions.resolve(prefix: "%", home: home, processPID: 0))
            XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(28)), home: home, processPID: 0))
        }
    }

    func testExistingUnavailableControlSocketMakesEvidenceIncomplete() throws {
        try withHome { home in
            try database(home, rows: [(first, "/current", "/current.jsonl")])
            let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
            try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: socket) // Not a live daemon, and must never trigger daemon startup.
            XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: 0))
        }
    }

    func testDirectProcessRolloutFilenamesRespectCustomHomeAndRejectCrossSourceCollision() throws {
        try withHome { home in
            let sessions = home.appendingPathComponent("sessions/2026/01/01")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let path = sessions.appendingPathComponent("rollout-2026-01-01T00-00-00-\(first).jsonl")
            // Deliberately invalid contents: identity discovery must only inspect the filename.
            try Data("not a conversation".utf8).write(to: path)
            let fd = Darwin.open(path.path, O_RDONLY)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            let selected = CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: getpid())
            XCTAssertEqual(selected?.sessionID, first)
            XCTAssertNil(selected?.cwd)
            try database(home, rows: [(first, "/same", path.path)])
            XCTAssertEqual(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: getpid())?.sessionID, first)
            try database(home, rows: [(collision, "/collision", "/collision.jsonl")], replace: true)
            XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: getpid()))
        }
    }

    func testRolloutOutsideSelectedHomeCannotResolveTitle() throws {
        try withHome { home in
            try withHome { other in
                let sessions = other.appendingPathComponent("sessions")
                try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
                let path = sessions.appendingPathComponent("rollout-time-\(first).jsonl")
                try Data().write(to: path)
                let fd = Darwin.open(path.path, O_RDONLY)
                guard fd >= 0 else { XCTFail("Cannot open fixture"); return }
                defer { Darwin.close(fd) }
                XCTAssertNil(CodexSessions.resolve(prefix: String(first.prefix(29)), home: home, processPID: getpid()))
            }
        }
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("helium-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func database(_ home: URL, rows: [(String, String, String)], replace: Bool = false) throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "CodexSessionTests", code: 1)
        }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT)", nil, nil, nil), SQLITE_OK)
        if replace { XCTAssertEqual(sqlite3_exec(db, "DELETE FROM threads", nil, nil, nil), SQLITE_OK) }
        for (id, cwd, file) in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?1, ?2, ?3)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "CodexSessionTests", code: 2)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            sqlite3_bind_text(statement, 2, cwd, -1, transient)
            sqlite3_bind_text(statement, 3, file, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }
}
