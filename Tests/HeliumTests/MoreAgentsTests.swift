import Foundation
import XCTest
@testable import helium_terminal

/// Pi, Kimi Code, Copilot CLI, Antigravity CLI, Grok Build, Hermes Agent and OpenCode V2.
final class MoreAgentsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

    func testProcessShapesAreRecognized() throws {
        // Node agents that set process.title leave the title and empty strings in KERN_PROCARGS2.
        let kimi = try XCTUnwrap(AgentInvocation(["kimi-code", "", "", ""]))
        XCTAssertEqual(kimi.kind, .kimi)
        XCTAssertEqual(kimi.arguments, [])
        XCTAssertTrue(kimi.interactive)
        XCTAssertEqual(AgentInvocation(["node", "/x/node_modules/@moonshot-ai/kimi-code/dist/main.mjs", "-y"])?.kind, .kimi)
        XCTAssertEqual(AgentInvocation(["pi", "", "", ""])?.kind, .pi)
        XCTAssertEqual(AgentInvocation(["node", "/x/node_modules/.bin/pi", "--thinking", "low"])?.kind, .pi)
        XCTAssertEqual(AgentInvocation(["node", "/x/@earendil-works/pi-coding-agent/dist/bundle/cli.js"])?.kind, .pi)
        XCTAssertEqual(AgentInvocation(["bun", "/x/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"])?.kind, .omp)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["/x/pi", "-p", "hi"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["/x/pi", "install", "npm:foo"])).interactive)

        // Copilot: npm's node loader is a launcher; extension hosts and subcommands aren't panes' agents.
        let loader = try XCTUnwrap(AgentInvocation(["node", "/usr/local/bin/copilot", "--model", "x"]))
        XCTAssertTrue(loader.isLauncher)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["copilot", "--model", "x", "-i", "fix it"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["copilot", "/c/pkg/preloads/extension_bootstrap.mjs"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["copilot", "--model", "x", "sessions"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["copilot", "-p", "hi"])).interactive)

        // agy: any subcommand (the `agentapi` helper, daemons) is not interactive; Go accepts -flag too.
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["agy", "--model", "m", "-mode", "plan"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["/home/.local/bin/agy", "agentapi", "--port", "1"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["agy", "-print", "hi"])).interactive)

        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["grok", "-m", "login", "fix the build"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["grok", "dashboard"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["grok", "sessions", "list"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["grok", "--single", "hi"])).interactive)

        // Hermes' launcher runs an inline bootstrap, so there is no `hermes` path in argv.
        let bootstrap = "import os, re, sys\nfrom hermes_cli.main import main\nsys.exit(main())"
        let hermes = try XCTUnwrap(AgentInvocation(["/x/python3.12", "-I", "-c", bootstrap, "--tui", "-p", "work"]))
        XCTAssertEqual(hermes.kind, .hermes)
        XCTAssertEqual(hermes.arguments, ["--tui", "-p", "work"])
        XCTAssertTrue(hermes.interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["/x/python3", "-I", "-c", bootstrap, "gateway", "run"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["/x/python3", "/x/bin/hermes", "chat", "-z", "hi"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["/x/python3", "/x/bin/hermes", "chat"])).interactive)
        XCTAssertNil(AgentInvocation(["/x/python3", "-c", "print(1)"]))
    }

    func testOpenCodeV2SubcommandsAndFlags() throws {
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["opencode", "mini", "-s", "ses_x"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["opencode", "service", "status"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["opencode", "--server", "service", "--standalone"])).interactive)
        XCTAssertEqual(AgentSession.resumableFlags(.opencode,
            ["--standalone", "--auto", "--session", "ses_old", "--server", "http://127.0.0.1:4096", "--prompt", "hi", "/repo"]),
                       ["--standalone", "--auto", "--server", "http://127.0.0.1:4096"])
        XCTAssertEqual(AgentSession.resumableFlags(.opencode, ["--server", "http://u:secret@h:1", "--server=http://u:p@h"]), [])
        XCTAssertEqual(AgentSession.resumableFlags(.opencode, ["--server=http://h:1/?a=b"]), ["--server=http://h:1/?a=b"])
    }

    func testResumeFlagsAndCommands() {
        XCTAssertEqual(AgentSession.resumableFlags(.copilot,
            ["--model", "gpt", "--resume", "abc", "--allow-tool", "shell", "write", "--yolo", "-i", "fix it",
             "--additional-mcp-config", "{\"token\":\"secret\"}", "--mouse", "--log-level", "debug"]),
                       ["--model", "gpt", "--allow-tool", "shell", "write", "--yolo", "--mouse", "--log-level", "debug"])
        XCTAssertEqual(AgentSession.resumableFlags(.agy,
            ["-model", "m", "--conversation=old", "--settings", "{}", "--sandbox", "-i", "hi"]), ["-model", "m", "--sandbox"])
        XCTAssertEqual(AgentSession.resumableFlags(.grok,
            ["-m", "grok-4", "-r", "--yolo", "--worktree", "--system-prompt", "x", "fix"]), ["-m", "grok-4", "--yolo"])
        XCTAssertEqual(AgentSession.resumableFlags(.hermes, ["-p", "work", "--model", "x", "--tui", "-r", "old"]),
                       ["-p", "work", "--tui"])
        XCTAssertEqual(AgentSession.resumableFlags(.pi, ["--model", "m", "--session", "/x.jsonl", "--api-key", "k", "-c"]),
                       ["--model", "m"])
        XCTAssertEqual(AgentSession.resumableFlags(.kimi, []), [])

        let uuid = "5525e01c-91e0-4e5c-bccd-66c78b8998f6"
        XCTAssertEqual(AgentSession(kind: .agy, sessionID: uuid, cwd: "/r", flags: []).resumeCommand,
                       "agy --conversation=\(uuid)")
        XCTAssertEqual(AgentSession(kind: .copilot, sessionID: uuid, cwd: "/r", flags: ["--yolo"]).resumeCommand,
                       "copilot --yolo --session-id \(uuid)")
        XCTAssertEqual(AgentSession(kind: .kimi, sessionID: "session_\(uuid)", cwd: "/r", flags: [],
                                    command: ["/k/bin/kimi"]).resumeCommand, "/k/bin/kimi -S session_\(uuid)")
        XCTAssertEqual(AgentSession(kind: .grok, sessionID: uuid, cwd: "/r", flags: [], unpersisted: true).resumeCommand, "grok")
    }

    func testPiResumesItsJournalOnlyOnceItExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helium-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("2026_01a1ecda.jsonl")
        let session = AgentSession(kind: .pi, sessionID: "01a1ecda-5c44-742f-9cd4-2e03e4da22dd", cwd: root.path,
                                   flags: ["--model", "m"], sessionFile: file.path)
        XCTAssertEqual(session.resumeCommand, "pi --model m") // nothing said yet: --session would invent a new ID there
        try Data("{}\n".utf8).write(to: file)
        XCTAssertEqual(session.resumeCommand, "pi --model m --session \(file.path)")
    }

    func testBlankedArgvLeavesTheCommandToTheKind() {
        let blank = AgentProcess.Arguments(argv: ["kimi-code", "", ""], environment: [:], executablePath: "/opt/node/bin/node",
                                           searchPath: "/nowhere", workingDirectory: "/")
        XCTAssertNil(AgentProcess.launchCommand(blank))
        let native = AgentProcess.Arguments(argv: ["kimi-code", ""], environment: [:], executablePath: "/k/bin/kimi",
                                            searchPath: "/nowhere", workingDirectory: "/")
        XCTAssertEqual(AgentProcess.launchCommand(native), ["/k/bin/kimi"])
        let python = AgentProcess.Arguments(argv: ["/x/python3", "-I", "-c", "boot"], environment: [:],
                                            executablePath: "/x/python3", searchPath: nil, workingDirectory: "/")
        XCTAssertNil(AgentProcess.launchCommand(python))
    }

    func testSessionIDsAreCheckedPerAgent() {
        XCTAssertTrue(AgentRegistration.validSessionID("session_953fdc59-596a-455c-b93e-d0d7a95569a5", kind: .kimi))
        XCTAssertFalse(AgentRegistration.validSessionID("953fdc59-596a-455c-b93e-d0d7a95569a5", kind: .kimi))
        XCTAssertFalse(AgentRegistration.validSessionID("session_x; rm -rf ~", kind: .kimi))
        XCTAssertTrue(AgentRegistration.validSessionID("my-session.v2", kind: .pi))
        XCTAssertFalse(AgentRegistration.validSessionID("-rf", kind: .pi))
        XCTAssertFalse(AgentRegistration.validSessionID("a/../b", kind: .pi))
        XCTAssertTrue(NativeSessions.validHermesID("20261118_041503_a1b2c3"))
        XCTAssertFalse(NativeSessions.validHermesID("20261118_041503_A1B2C3"))
        XCTAssertFalse(NativeSessions.validHermesID("2026111_041503_a1b2c3"))
    }

    func testLogTieBreakTakesTheLastSwitchAmongOpenSessions() {
        let a = "7eaa1ea6-5eee-4973-8af5-5c3ca1e62e89", b = "ffa6a56c-c744-485f-870f-4068abe8876f"
        let log = """
        2026-11-18T04:15:13.184Z [INFO] Registering foreground session: \(a)
        2026-11-18T04:15:38.091Z [INFO] Unregistering foreground session: \(a)
        2026-11-18T04:15:38.095Z [INFO] Registering foreground session: \(b)
        2026-11-18T04:16:00.000Z [INFO] Unregistering foreground session: \(b)
        """
        let marker = "] Registering foreground session: "
        XCTAssertEqual(NativeSessions.lastMatch(in: log, after: marker, among: [a, b]), b)
        XCTAssertEqual(NativeSessions.lastMatch(in: log, after: marker, among: [a]), a) // b is no longer open
        XCTAssertNil(NativeSessions.lastMatch(in: log, after: marker, among: ["00000000-0000-0000-0000-000000000000"]))
        XCTAssertEqual(NativeSessions.yamlCwd("id: \(a)\ncwd: /Users/demo/repo\nname: x\n"), "/Users/demo/repo")
        XCTAssertEqual(NativeSessions.yamlCwd("cwd: \"/a b/c\"\n"), "/a b/c")
        XCTAssertNil(NativeSessions.yamlCwd("cwd: \"/a\\\"b\"\n"))
    }

    func testKimiHookIsAppendedOnceAndNeverClobbersInlineHooks() throws {
        let command = "exec /bin/sh '/Users/a b/.kimi-code/helium-terminal-hook.sh' kimi"
        let base = "default_model = \"k2\"\n\n[providers.k]\ntype = \"openai\""
        let once = try AgentConfig.addingKimiHook(base, command: command, marker: "helium-terminal-hook.sh")
        XCTAssertTrue(once.hasPrefix(base + "\n"))
        XCTAssertTrue(once.contains("[[hooks]]\nevent = \"SessionStart\"\ncommand = \"exec /bin/sh '/Users/a b/.kimi-code/helium-terminal-hook.sh' kimi\"\n"))
        XCTAssertEqual(try AgentConfig.addingKimiHook(once, command: command, marker: "helium-terminal-hook.sh"), once)
        XCTAssertNoThrow(try AgentConfig.addingKimiHook("[[hooks]]\nevent = \"Stop\"\ncommand = \"x\"\n", command: command,
                                                         marker: "helium-terminal-hook.sh"))
        XCTAssertThrowsError(try AgentConfig.addingKimiHook("hooks = []\n", command: command, marker: "helium-terminal-hook.sh"))
        XCTAssertThrowsError(try AgentConfig.addingKimiHook("[hooks]\nx = 1\n", command: command, marker: "helium-terminal-hook.sh"))
    }

    func testHookScriptReportsTheAgentAsItsParent() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("helium-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let script = AgentIntegrations.resourceDirectory.appendingPathComponent("hook.sh").path
        // Like Kimi Code: `sh -c "exec /bin/sh <script> kimi"` with the hook JSON on stdin.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec /bin/sh '\(script)' kimi"]
        process.environment = ["HELIUM_PANE": "1", "HELIUM_PANE_TOKEN": "0123abcd-ef", "HELIUM_AGENT_STATE_DIR": state.path,
                               "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"SessionStart","session_id":"session_953fdc59-596a-455c-b93e-d0d7a95569a5","cwd":"/r"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("\(me).json"))) as? [String: Any]
        XCTAssertEqual(report?["kind"] as? String, "kimi")
        XCTAssertEqual(report?["sessionID"] as? String, "session_953fdc59-596a-455c-b93e-d0d7a95569a5")
        XCTAssertEqual(report?["pid"] as? Int, Int(me))
        XCTAssertEqual(report?["token"] as? String, "0123abcd-ef")
    }

    func testGrokTakesThisProcessesNewestSessionAndChecksItWasSaved() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("helium-grok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let saved = "01a1ecda-5c44-742f-9cd4-2e03e4da22dd", husk = "01a1ecda-c138-742f-9cd4-2e0404c2b711"
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions/%2Frepo/\(saved)"),
                                                withIntermediateDirectories: true)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        func write(_ entries: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: entries).write(to: home.appendingPathComponent("active_sessions.json"))
        }
        let process = try XCTUnwrap(AgentProcess(identity: XCTUnwrap(AgentProcess.identity(pid_t(me))),
                                                 invocation: XCTUnwrap(AgentInvocation(["grok", "--yolo"])),
                                                 environment: ["GROK_HOME": home.path], command: ["/g/grok"]))
        try write([["session_id": saved, "pid": me, "cwd": "/repo", "opened_at": "2026-11-18T04:00:00Z"],
                   ["session_id": husk, "pid": me + 1, "cwd": "/repo", "opened_at": "2026-11-18T05:00:00Z"]])
        let first = try XCTUnwrap(NativeSessions.grok(process))
        XCTAssertEqual(first.sessionID, saved)
        XCTAssertEqual(first.cwd, "/repo")
        XCTAssertEqual(first.resumeCommand, "export GROK_HOME=\(AgentSession.shellQuote(home.path)); /g/grok --yolo --resume \(saved)")
        try write([["session_id": saved, "pid": me, "opened_at": "2026-11-18T04:00:00Z"],
                   ["session_id": husk, "pid": me, "opened_at": "2026-11-18T05:00:00Z"]])
        let second = try XCTUnwrap(NativeSessions.grok(process))
        XCTAssertEqual(second.sessionID, husk)
        XCTAssertTrue(second.resumeCommand.hasSuffix("/g/grok --yolo")) // never saved: start fresh
        try write([["session_id": saved, "pid": me + 1, "opened_at": "2026-11-18T04:00:00Z"]])
        XCTAssertNil(NativeSessions.grok(process))
    }
}
