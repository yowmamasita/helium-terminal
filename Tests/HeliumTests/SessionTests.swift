import Foundation
import XCTest
@testable import helium_terminal

final class SessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

    func testClaudeResumeKeepsFlagsAndDropsResumeAndPrompt() {
        let flags = AgentSession.resumableFlags(.claude,
            ["--dangerously-skip-permissions", "--remote-control", "--model", "opus", "-r"])
        XCTAssertEqual(flags, ["--dangerously-skip-permissions", "--remote-control", "--model", "opus"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--resume", "abc-123", "--model", "opus"]), ["--model", "opus"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["-c", "fix the failing test"]), [])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--resume=abc", "--verbose"]), ["--verbose"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--system-prompt", "--continue"]),
                       ["--system-prompt", "--continue"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--allowedTools", "Bash", "Read", "--", "fix"]),
                       ["--allowedTools", "Bash", "Read"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--add-dir", "/a", "/b", "--", "fix"]),
                       ["--add-dir", "/a", "/b"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--settings", "{\"a\":\"b,c\"}", "fix"]),
                       ["--settings", "{\"a\":\"b,c\"}"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--debug", "api,hooks", "--verbose"]),
                       ["--debug", "api,hooks", "--verbose"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--debug", "--verbose"]),
                       ["--debug", "--verbose"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--", "fix"]), [])
        XCTAssertEqual(AgentSession.resumableFlags(.claude,
                                                   ["--model", "opus", "fix the bug", "--permission-mode", "plan"]),
                       ["--model", "opus", "--permission-mode", "plan"])

        let s = AgentSession(kind: .claude, sessionID: "ec03a3f0-360a-4d62-8014-20b4d520432d", cwd: "/tmp",
                             flags: ["--model", "opus", "--append-system-prompt", "be brief; it's fine"])
        XCTAssertEqual(s.resumeCommand,
            "claude --model opus --append-system-prompt 'be brief; it'\\''s fine' --resume ec03a3f0-360a-4d62-8014-20b4d520432d")
    }

    func testCodexResumeDropsSubcommandAndLast() {
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["resume", "--last", "--model", "gpt-5.5"]), ["--model", "gpt-5.5"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["--yolo", "refactor the parser"]), ["--yolo"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex,
                                                   ["--model", "gpt-5.5", "fix", "--sandbox", "read-only"]),
                       ["--model", "gpt-5.5", "--sandbox", "read-only"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex,
                                                   ["--image", "one.png", "two.png", "--", "describe"]),
                       ["--image", "one.png", "two.png"])
        let s = AgentSession(kind: .codex, sessionID: "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", cwd: nil, flags: ["--yolo"])
        XCTAssertEqual(s.resumeCommand, "codex resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b --yolo")
    }

    func testStateRoundTrips() throws {
        let agent = AgentSession(kind: .claude, sessionID: "id", cwd: "/repo", flags: ["--model", "opus"])
        let state = SessionState(tabs: [
            .split(vertical: true, ratio: 0.6, first: .pane(cwd: "/repo", agent: agent),
                   second: .split(vertical: false, ratio: 0.5, first: .pane(cwd: "/repo", agent: nil),
                                  second: .pane(cwd: nil, agent: nil))),
            .pane(cwd: "/tmp", agent: nil),
        ], selected: 1)
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.tabs[0].firstPane.agent, agent)
    }

    func testClaudeSessionFixture() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "pid": 42, "sessionId": "ec03a3f0-360a-4d62-8014-20b4d520432d",
            "kind": "interactive", "status": "busy",
        ])
        XCTAssertEqual(Agents.claudeSession(data, pid: 42)?.id, "ec03a3f0-360a-4d62-8014-20b4d520432d")
        XCTAssertNil(Agents.claudeSession(data, pid: 43))
    }

    func testClaudeStatusMeansRunning() throws {
        func session(_ status: String?) -> (id: String, running: Bool, unblockedAt: Date?)? {
            var obj: [String: Any] = ["pid": 42, "sessionId": "abc", "kind": "interactive", "statusUpdatedAt": 1_791_951_251_478]
            obj["status"] = status
            return Agents.claudeSession(try! JSONSerialization.data(withJSONObject: obj), pid: 42)
        }
        XCTAssertEqual(session("busy")?.running, true)
        XCTAssertEqual(session("shell")?.running, true) // idle, but a background shell or monitor is going
        XCTAssertEqual(session("idle")?.running, false)
        XCTAssertEqual(session(nil)?.running, false)
        XCTAssertEqual(session("shell")?.id, "abc")
        // Blocked on a question; once answered (anywhere) the status moves on and its time is reported.
        XCTAssertNil(session("waiting")!.unblockedAt)
        XCTAssertEqual(session("busy")?.unblockedAt, Date(timeIntervalSince1970: 1_791_951_251.478))
        // Polled state never reaches state.json.
        var agent = AgentSession(kind: .claude, sessionID: "id", cwd: nil, flags: [])
        agent.running = true
        let json = String(decoding: try JSONEncoder().encode(agent), as: UTF8.self)
        XCTAssertFalse(json.contains("running"))
        XCTAssertFalse(try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8)).running)
    }

    func testResumeTemplates() {
        let s = AgentSession(kind: .claude, sessionID: "abc", cwd: "/my repo", flags: ["--model", "opus"])
        XCTAssertEqual(s.resumeCommand(template: AgentSession.defaultTemplate(for: .claude)),
                       "claude --model opus --resume abc")
        XCTAssertEqual(s.resumeCommand(template: "cc --resume {id}"), "cc --resume abc")
        XCTAssertEqual(s.resumeCommand(template: "cd {cwd} && claude {flags} -r {id}"),
                       "cd '/my repo' && claude --model opus -r abc")
        let spaced = AgentSession(kind: .claude, sessionID: "abc", cwd: "/a  b", flags: [])
        XCTAssertEqual(spaced.resumeCommand(template: "cd {cwd} && claude {flags} --resume {id}"),
                       "cd '/a  b' && claude --resume abc")
        let none = AgentSession(kind: .codex, sessionID: "x", cwd: nil, flags: [])
        XCTAssertEqual(none.resumeCommand(template: AgentSession.defaultTemplate(for: .codex)), "codex resume x")
    }

    func testOldStateFilesStillLoadAndTitlesRoundTrip() throws {
        let old = #"{"selected":0,"tabs":[{"pane":{"cwd":"/tmp"}}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionState.self, from: old)
        XCTAssertNil(decoded.titles)
        var state = decoded
        state.titles = ["API work"]
        state.labels = [["urgent", "client"]]
        state.groups = [.init(id: "g1", name: "API", color: "Blue", collapsed: true)]
        state.tabGroups = ["g1"]
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state)), state)
    }

    func testScrollMultiplierParsing() {
        XCTAssertTrue(SettingsWindow.scrollMultipliers("precision:1,discrete:3") == (1, 3))
        XCTAssertTrue(SettingsWindow.scrollMultipliers("precision:0.5") == (0.5, 3))
        XCTAssertTrue(SettingsWindow.scrollMultipliers("2") == (2, 2))
        XCTAssertTrue(SettingsWindow.scrollMultipliers("") == (1, 3))
    }

    func testFlagValuesWithSpacesAreKept() {
        // A spaced value after an option that takes text is that option's value, not an initial prompt.
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--allowedTools", "Bash(git *)", "--", "fix it"]),
                       ["--allowedTools", "Bash(git *)"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--permission-mode", "plan", "fix it"]),
                       ["--permission-mode", "plan"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--name", "API work", "fix it"]),
                       ["--name", "API work"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--verbose", "fix it"]), ["--verbose"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--verbose", "fix"]), ["--verbose"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["--yolo", "refactor"]), ["--yolo"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["--profile", "work", "refactor"]), ["--profile", "work"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["--enable", "feature", "refactor"]), ["--enable", "feature"])
    }

    func testCodexSubcommandSkipsOptionValues() {
        XCTAssertNil(Agents.codexSubcommand(["--profile", "exec"]))
        XCTAssertEqual(Agents.codexSubcommand(["--profile", "work", "exec"]), "exec")
        XCTAssertNil(Agents.codexSubcommand(["--enable", "exec"]))
        XCTAssertEqual(Agents.codexSubcommand(["--config=exec"]), nil)
        XCTAssertNil(Agents.codexSubcommand(["--", "review"]))
        XCTAssertNil(Agents.codexSubcommand(["--profile", "--", "review"]))
    }

    func testPersistedSplitRatiosPreserveValidValues() {
        XCTAssertEqual(MainWindowController.boundedRatio(.nan), 0.5)
        XCTAssertEqual(MainWindowController.boundedRatio(-1), 0.5)
        XCTAssertEqual(MainWindowController.boundedRatio(2), 0.5)
        XCTAssertEqual(MainWindowController.boundedRatio(0.01), 0.01)
        XCTAssertEqual(MainWindowController.boundedRatio(0.99), 0.99)
        XCTAssertEqual(MainWindowController.boundedRatio(0.6), 0.6)
    }

    func testTemplateIsFilledInOnePass() {
        let s = AgentSession(kind: .claude, sessionID: "abc", cwd: "/x y", flags: ["--settings", "{cwd}"])
        XCTAssertEqual(s.resumeCommand(template: "cd {cwd} && claude {flags} -r {id} {unknown}"),
                       "cd '/x y' && claude --settings '{cwd}' -r abc {unknown}")
        XCTAssertEqual(AgentSession.shellQuote("=ls"), "'=ls'")
        XCTAssertEqual(AgentSession.shellQuote("a=b"), "a=b")
    }

    func testGitStatusParsingAndBranchLine() throws {
        let clean = Metadata.parseGitStatus("# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -1\n")
        XCTAssertEqual(clean, .init(ahead: 2, behind: 1, dirty: false))
        XCTAssertEqual(Metadata.parseGitStatus("# branch.head main\n1 .M N... 100644 100644 100644 a b f.swift\n"),
                       .init(ahead: 0, behind: 0, dirty: true)) // no upstream, so no branch.ab line
        XCTAssertEqual(Metadata.parseGitStatus("# branch.ab +0 -0\n? new.txt\n").dirty, true)
        XCTAssertEqual(Metadata.branchParts("main", clean), ["⎇ main", "↑2 ahead  ↓1 behind"])
        XCTAssertEqual(Metadata.branchParts("main", .init(ahead: 0, behind: 3, dirty: true)),
                       ["⎇ main", "↓3 behind", "● uncommitted changes"])
        XCTAssertEqual(Metadata.branchParts("main", .init()), ["⎇ main"])
        XCTAssertEqual(Metadata.branchParts("main", nil), ["⎇ main"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helium-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", dir.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        XCTAssertNotNil(Metadata.gitStatus(dir.path))
    }
}
