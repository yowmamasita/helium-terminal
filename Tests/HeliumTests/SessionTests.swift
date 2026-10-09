import XCTest
@testable import helium_terminal

final class SessionTests: XCTestCase {
    func testClaudeResumeKeepsFlagsAndDropsResumeAndPrompt() {
        let flags = AgentSession.resumableFlags(.claude,
            ["--dangerously-skip-permissions", "--remote-control", "--model", "opus", "-r"])
        XCTAssertEqual(flags, ["--dangerously-skip-permissions", "--remote-control", "--model", "opus"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--resume", "abc-123", "--model", "opus"]), ["--model", "opus"])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["-c", "fix the failing test"]), [])
        XCTAssertEqual(AgentSession.resumableFlags(.claude, ["--resume=abc", "--verbose"]), ["--verbose"])

        let s = AgentSession(kind: .claude, sessionID: "ec03a3f0-360a-4d62-8014-20b4d520432d", cwd: "/tmp",
                             flags: ["--model", "opus", "--append-system-prompt", "be brief; it's fine"])
        XCTAssertEqual(s.resumeCommand,
            "claude --model opus --append-system-prompt 'be brief; it'\\''s fine' --resume ec03a3f0-360a-4d62-8014-20b4d520432d")
    }

    func testCodexResumeDropsSubcommandAndLast() {
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["resume", "--last", "--model", "gpt-5.5"]), ["--model", "gpt-5.5"])
        XCTAssertEqual(AgentSession.resumableFlags(.codex, ["--yolo", "refactor the parser"]), ["--yolo"])
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

    /// Reads a real running Claude Code session, if one exists (this suite often runs inside one).
    func testFindsRunningClaudeSession() throws {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        sysctl(&mib, 4, &procs, &size, nil, 0)
        let pid = try XCTUnwrap(procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid).first {
            Agents.arguments(of: $0)?.first.map { ($0 as NSString).lastPathComponent } == "claude"
                && Agents.claudeSessionID(pid: $0) != nil
        }, "no interactive claude session running")
        let id = try XCTUnwrap(Agents.claudeSessionID(pid: pid))
        XCTAssertNotNil(UUID(uuidString: id))
        let argv = try XCTUnwrap(Agents.arguments(of: pid))
        XCTAssertEqual((argv.first as NSString?)?.lastPathComponent, "claude")
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
}
