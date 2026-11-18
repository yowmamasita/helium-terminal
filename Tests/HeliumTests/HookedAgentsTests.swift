import Foundation
import SQLite3
import XCTest
@testable import helium_terminal

/// MiniMax Code, ZCode and Cline.
final class HookedAgentsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

    private let marker = "helium-terminal-hook.sh"
    private let command = "/bin/sh '/Users/a b/.minimax/helium-terminal-hook.sh' mcode"

    func testMiniMaxStatusLineIsAddedToTheConfigMiniMaxWrites() throws {
        let fresh = try AgentConfig.addingMiniMaxStatusLine("", command: command, marker: marker)
        XCTAssertTrue(fresh.hasPrefix("tui:\n  statusLine:\n    - current-dir\n"))
        XCTAssertTrue(fresh.contains("    - custom-command\n  customStatusLine:\n    command: \"/bin/sh '/Users/a b/.minimax/helium-terminal-hook.sh' mcode\"\n"))
        XCTAssertEqual(try AgentConfig.addingMiniMaxStatusLine(fresh, command: command, marker: marker), fresh)

        // js-yaml's own layout, with the user's chosen items: only custom-command and our block are added.
        let chosen = "provider:\n  x: 1\ntui:\n  statusLine:\n    - git-branch\n    - model\n  theme: dark\nother: true\n"
        let edited = try AgentConfig.addingMiniMaxStatusLine(chosen, command: command, marker: marker)
        XCTAssertTrue(edited.hasPrefix("provider:\n  x: 1\ntui:\n  customStatusLine:\n"))
        XCTAssertTrue(edited.hasSuffix("  statusLine:\n    - git-branch\n    - model\n    - custom-command\n  theme: dark\nother: true\n"))
        XCTAssertEqual(try AgentConfig.addingMiniMaxStatusLine(edited, command: command, marker: marker), edited)

        // MiniMax's picker rewrites statusLine and can drop custom-command; it comes back, nothing else changes.
        let picked = edited.replacingOccurrences(of: "    - custom-command\n", with: "")
        XCTAssertEqual(try AgentConfig.addingMiniMaxStatusLine(picked, command: command, marker: marker), edited)

        let flow = try AgentConfig.addingMiniMaxStatusLine("tui:\n  statusLine: [git-branch, 'model']\n", command: command, marker: marker)
        XCTAssertTrue(flow.contains("  statusLine: [git-branch, model, custom-command]\n"))

        XCTAssertThrowsError(try AgentConfig.addingMiniMaxStatusLine("tui:\n  customStatusLine:\n    command: my-status\n",
                                                                     command: command, marker: marker)) // the user's own
        XCTAssertThrowsError(try AgentConfig.addingMiniMaxStatusLine("tui:\n  statusLine:\n    - build-mode\n",
                                                                     command: command, marker: marker))
        XCTAssertThrowsError(try AgentConfig.addingMiniMaxStatusLine("tui: {theme: dark}\n", command: command, marker: marker))
    }

    func testZCodeHooksAreInsertedWithoutReformattingAndEnableHooks() throws {
        let entry = #"{"hooks":[{"args":["/h/.zcode/cli/helium-terminal-hook.sh","zcode"],"command":"/bin/sh","type":"process"}]}"#
        let stop = #"{"hooks":[{"args":["/h/.zcode/cli/helium-terminal-hook.sh","zcode","idle"],"command":"/bin/sh","type":"process"}]}"#
        let both = [(event: "SessionStart", entry: entry), (event: "Stop", entry: stop)]
        let empty = try AgentConfig.addingZCodeHooks("", both, marker: marker)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(((hooks["events"] as? [String: Any])?["SessionStart"] as? [Any])?.count, 1)
        XCTAssertEqual(((hooks["events"] as? [String: Any])?["Stop"] as? [Any])?.count, 1)

        let existing = """
        {
          // the user's own
          "locale": "en",
          "hooks": {
            "enabled": false,
            "events": {
              "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }],
              "SessionStart": [{ "hooks": [{ "type": "command", "command": "echo hi" }] }]
            }
          }
        }
        """
        let edited = try AgentConfig.addingZCodeHooks(existing, both, marker: marker)
        XCTAssertEqual(edited, existing.replacingOccurrences(of: "\"enabled\": false", with: "\"enabled\": true")
            .replacingOccurrences(of: "\"SessionStart\": [{", with: "\"SessionStart\": [\(entry),{")
            .replacingOccurrences(of: "\"Stop\": [{", with: "\"Stop\": [\(stop),{"))
        XCTAssertEqual(try AgentConfig.addingZCodeHooks(edited, both, marker: marker), edited)

        // A 0.1.13 install has only SessionStart; the rest is added, and "enabled": false is the user's choice.
        let old = #"{"hooks": {"enabled": false, "events": {"SessionStart": ["# + entry + #"]}}}"#
        XCTAssertEqual(try AgentConfig.addingZCodeHooks(old, both, marker: marker),
                       #"{"hooks": {"enabled": true, "events": {"Stop":["# + stop + #"],"SessionStart": ["# + entry + #"]}}}"#)
        XCTAssertEqual(try AgentConfig.addingZCodeHooks(old, [both[0]], marker: marker), old)
        let noEvents = try AgentConfig.addingZCodeHooks(#"{"hooks": {"x": 1}}"#, [both[0]], marker: marker)
        XCTAssertEqual(noEvents, #"{"hooks": {"enabled":true,"events":{"SessionStart":["# + entry + #"]},"x": 1}}"#)
        XCTAssertThrowsError(try AgentConfig.addingZCodeHooks(#"{"hooks": []}"#, both, marker: marker))
    }

    func testIndicatorPhrasesAndTitles() {
        // Kimi Code, Grok, OpenCode V2 and omp ask for input with these; Claude's idle reminder is still done.
        for text in ["Kimi Code approval required: Shell", "Kimi Code needs your answer: which branch?",
                     "Grok: Approval required", "opencode: Input needs response", "omp: Waiting for input",
                     "MCode: x: Permission needs your input", "Copilot: Needs approval",
                     "Antigravity CLI needs tool confirmation"] {
            XCTAssertTrue(Workspace.isWaitingForInput(text), text)
        }
        XCTAssertFalse(Workspace.isWaitingForInput("Claude Code: Claude is waiting for your input"))
        XCTAssertFalse(Workspace.isWaitingForInput("Kimi Code task complete"))
        XCTAssertTrue(Workspace.isWorking(title: "\u{23F3} hermes · model · ~/repo"))
        XCTAssertTrue(Workspace.isWorking(title: "\u{280B} fixing tests - grok"))
        XCTAssertFalse(Workspace.isWorking(title: "\u{2713} hermes · model · ~/repo"))
        XCTAssertTrue(Workspace.titleAsksForInput("\u{26A0} hermes · model"))
        XCTAssertTrue(Workspace.titleAsksForInput("\u{280B} Action required - grok"))
        XCTAssertFalse(Workspace.titleAsksForInput("OpenCode"))
    }

    func testHookWithoutASessionReportsNone() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("helium-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        // Like MiniMax's status line and ZCode's process hooks: the agent spawns /bin/sh directly.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [AgentIntegrations.resourceDirectory.appendingPathComponent("hook.sh").path, "mcode"]
        process.environment = ["HELIUM_PANE": "1", "HELIUM_PANE_TOKEN": "0123abcd-ef", "HELIUM_AGENT_STATE_DIR": state.path,
                               "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"protocol":1,"event":"session-change","workspace_dir":"/r"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("\(me).json"))) as? [String: Any]
        XCTAssertEqual(report?["kind"] as? String, "mcode")
        XCTAssertTrue(report?["sessionID"] is NSNull)
        XCTAssertNil(report?["state"])

        // ZCode's turn hooks pass a state.
        let stateful = Process()
        stateful.executableURL = URL(fileURLWithPath: "/bin/sh")
        stateful.arguments = [AgentIntegrations.resourceDirectory.appendingPathComponent("hook.sh").path, "zcode", "blocked"]
        stateful.environment = process.environment
        let pipe = Pipe()
        stateful.standardInput = pipe
        try stateful.run()
        pipe.fileHandleForWriting.write(Data(#"{"session_id":"sess_953fdc59-596a-455c-b93e-d0d7a95569a5"}"#.utf8))
        try pipe.fileHandleForWriting.close()
        stateful.waitUntilExit()
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("\(me).json"))) as? [String: Any]
        XCTAssertEqual(second?["state"] as? String, "blocked")
        XCTAssertEqual(second?["sessionID"] as? String, "sess_953fdc59-596a-455c-b93e-d0d7a95569a5")
    }

    func testProcessShapesIDsAndFlags() throws {
        for (title, kind) in [("minimax-code", AgentSession.Kind.mcode), ("zcode-cli", .zcode), (".cline", .cline)] {
            let invocation = try XCTUnwrap(AgentInvocation([title, "", ""]))
            XCTAssertEqual(invocation.kind, kind)
        }
        XCTAssertEqual(AgentInvocation(["node", "/x/lib/node_modules/@minimax-ai/code/cli.js", "-m", "x"])?.kind, .mcode)
        XCTAssertEqual(AgentInvocation(["node", "/z/current/bin/zcode.mjs"])?.kind, .zcode)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["node", "/n/lib/node_modules/cline/bin/cline"])).isLauncher)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["/n/cline/bin/.cline", "-m", "x", "--thinking"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation([".cline", "-i", "fix the build"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation([".cline", "fix the build"])).interactive) // one-shot
        XCTAssertFalse(try XCTUnwrap(AgentInvocation([".cline", "--cline-hub-daemon", "--port", "25463"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["cline", "-i", "history"])).interactive)
        XCTAssertEqual(AgentSession.resumableFlags(.cline,
            ["-m", "x", "--id", "1794976698562_v6o3q", "-k", "secret", "--thinking", "-p", "--auto-approve", "false", "-i", "go"]),
                       ["-m", "x", "--thinking", "-p", "--auto-approve", "false", "-i"])

        XCTAssertTrue(AgentRegistration.validSessionID("mvs_2b1016d68293451ea27f23367fafd05c", kind: .mcode))
        XCTAssertFalse(AgentRegistration.validSessionID("mvs_2B1016D68293451EA27F23367FAFD05C", kind: .mcode))
        XCTAssertTrue(AgentRegistration.validSessionID("sess_953fdc59-596a-455c-b93e-d0d7a95569a5", kind: .zcode))
        XCTAssertFalse(AgentRegistration.validSessionID("sess_dwf-953fdc59-596a-455c-b93e-d0d7a955", kind: .zcode))
        XCTAssertTrue(ClineSessions.validID("1794976698562_v6o3q"))
        XCTAssertFalse(ClineSessions.validID("1794976698562_V6O3Q"))
        XCTAssertFalse(ClineSessions.validID("conv_1794976698562_v6o3q12"))

        let id = "mvs_2b1016d68293451ea27f23367fafd05c"
        XCTAssertEqual(AgentSession(kind: .mcode, sessionID: id, cwd: "/r", flags: []).resumeCommand, "mcode --session \(id)")
        XCTAssertEqual(AgentSession(kind: .zcode, sessionID: "sess_x", cwd: "/r", flags: []).resumeCommand, "zcode --resume sess_x")
        XCTAssertEqual(AgentSession(kind: .cline, sessionID: "1794976698562_v6o3q", cwd: "/r", flags: ["-p"],
                                    command: ["/n/.cline"]).resumeCommand, "/n/.cline -p --id 1794976698562_v6o3q")
    }

    /// The first pane's session runs in its own process; later panes' run in the hub, which logs who created them.
    func testClineSessionsComeFromTheProcessOrTheHubLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helium-cline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, _ sql: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
            return url
        }
        let sessions = try make("sessions.db", """
            CREATE TABLE sessions (session_id TEXT PRIMARY KEY, pid INTEGER, started_at TEXT, interactive INTEGER,
              is_subagent INTEGER, cwd TEXT);
            INSERT INTO sessions VALUES ('1794976698562_v6o3q', 100, '2026-11-18T04:38:18.563Z', 1, 0, '/repo');
            INSERT INTO sessions VALUES ('1794976600000_old00', 100, '2026-11-18T04:00:00.000Z', 1, 0, '/repo');
            INSERT INTO sessions VALUES ('1794976704217_s0tjq', 200, '2026-11-18T04:38:24.220Z', 1, 0, '/repo');
            """)
        func event(_ seq: Int, _ name: String, _ session: String?, _ payload: String, _ at: Int) -> String {
            "INSERT INTO hub_events VALUES (\(seq), '\(name)', \(session.map { "'\($0)'" } ?? "NULL"), '{\"payload\":\(payload)}', \(at));"
        }
        let hub = try make("hub-events-hub-production.db", """
            CREATE TABLE hub_events (sequence INTEGER PRIMARY KEY, event TEXT, session_id TEXT, envelope_json TEXT, created_at INTEGER);
            \(event(1, "hub.client.registered", nil, #"{"clientId":"hc","clientType":"hub-healthcheck","metadata":{"pid":100}}"#, 1794976690000))
            \(event(2, "hub.client.registered", nil, #"{"clientId":"b","clientType":"cli","metadata":{"pid":300}}"#, 1794976699000))
            \(event(3, "session.created", "1794976704217_s0tjq", #"{"session":{"createdByClientId":"b","cwd":"/repo"}}"#, 1794976704217))
            \(event(4, "session.created", "1794976749243_enjoc", #"{"session":{"createdByClientId":"b","cwd":"/repo"}}"#, 1794976749243))
            \(event(5, "session.created", "1794976800000_other", #"{"session":{"createdByClientId":"hc"}}"#, 1794976800000))
            """)
        let started = 1794976690.0
        XCTAssertEqual(ClineSessions.inProcess(sessions, pid: 100, since: started)?.id, "1794976698562_v6o3q")
        XCTAssertNil(ClineSessions.inProcess(sessions, pid: 100, since: 1794976800)) // rows from before this process
        XCTAssertNil(ClineSessions.hubCreated(hub, pid: 100, since: started)) // health checks aren't panes
        let latest = try XCTUnwrap(ClineSessions.hubCreated(hub, pid: 300, since: started))
        XCTAssertEqual(latest.id, "1794976749243_enjoc") // after /clear and a new prompt
        XCTAssertEqual(latest.cwd, "/repo")
        XCTAssertNil(ClineSessions.hubCreated(hub, pid: 300, since: 1794976750))
        XCTAssertNil(ClineSessions.status(sessions, id: "1794976698562_v6o3q")) // this fixture has no status column
    }
}
