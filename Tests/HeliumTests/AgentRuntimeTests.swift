import Darwin
import Foundation
import XCTest
@testable import helium_terminal

final class AgentRuntimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

    func testLaunchCommandUsesOriginalPATHAndDirectoryRatherThanHeliums() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let alias = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/bin/sleep")
        let relative = AgentProcess.Arguments(argv: ["codex"], environment: [:], executablePath: "/bin/sleep",
                                              searchPath: "missing:bin", workingDirectory: root.path)
        XCTAssertEqual(AgentProcess.launchCommand(relative), [alias.path])
        let unavailable = AgentProcess.Arguments(argv: ["codex"], environment: [:], executablePath: "/bin/sleep",
                                                 searchPath: nil, workingDirectory: nil)
        XCTAssertEqual(AgentProcess.launchCommand(unavailable), ["/bin/sleep"])
        let interpreted = AgentProcess.Arguments(argv: ["bun", "../harness/omp"], environment: [:],
                                                 executablePath: "/original/bun", searchPath: nil,
                                                 workingDirectory: bin.path)
        XCTAssertEqual(AgentProcess.launchCommand(interpreted), ["/original/bun", root.appendingPathComponent("harness/omp").path])
    }

    func testInterpreterAndNativeAgentsAreDistinguishedFromOtherPrograms() throws {
        XCTAssertEqual(AgentInvocation(["bun", "/demo/.bun/bin/omp", "--profile", "work"])?.kind, .omp)
        XCTAssertEqual(AgentInvocation(["bun", "/demo/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"])?.kind, .omp)
        XCTAssertEqual(AgentInvocation(["/demo/claude", "--model", "opus"])?.kind, .claude)
        XCTAssertNil(AgentInvocation(["bun", "/demo/cli.js", "omp"]))
        XCTAssertNil(AgentInvocation(["node", "/demo/server.js", "codex"]))
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["codex", "--profile", "work", "exec", "task"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["codex", "--profile", "exec"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["bun", "omp", "__omp_worker_text_predict"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["bun", "omp", "--mode=rpc"])).interactive)
        XCTAssertFalse(try XCTUnwrap(AgentInvocation(["opencode", "run", "task"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["opencode", "--agent", "run"])).interactive)
        XCTAssertTrue(try XCTUnwrap(AgentInvocation(["bun", "omp", "--system-prompt", "--print"])).interactive)
    }

    func testOneShotInputAndCredentialsAreNotReplayed() {
        XCTAssertEqual(AgentSession.resumableFlags(.omp,
            ["--resume", "old", "--model", "provider/model", "--goal", "original task", "--api-key", "secret",
             "--profile", "work", "@image.png", "--", "initial prompt"]),
                       ["--model", "provider/model", "--profile", "work"])
        XCTAssertEqual(AgentSession.resumableFlags(.opencode,
            ["--session", "old", "--model", "provider/model", "--fork", "--continue", "--password", "secret", "--prompt", "task"]),
                       ["--model", "provider/model"])
        XCTAssertEqual(AgentSession.resumableFlags(.opencode,
            ["attach", "http://127.0.0.1:1234", "--dir", "/repo", "--session", "old"]),
                       ["attach", "http://127.0.0.1:1234", "--dir", "/repo"])
        XCTAssertFalse(AgentSession.resumableFlags(.opencode, ["attach", "http://user:secret@example.test"]).contains { $0.contains("secret") })
    }

    func testProcessArgumentsRetainOnlyNonSecretLocationOverrides() throws {
        var bytes = withUnsafeBytes(of: Int32(2)) { Array($0) }
        bytes += Array("/path/to/bun\0\0bun\0/demo/omp\0CODEX_HOME=/demo/codex\0OPENAI_API_KEY=secret\0OPENCODE_CONFIG_CONTENT=secret\0HELIUM_PANE_TOKEN=secret\0\0".utf8)
        let parsed = try XCTUnwrap(AgentProcess.parse(bytes[...]))
        XCTAssertEqual(parsed.argv, ["bun", "/demo/omp"])
        XCTAssertEqual(parsed.environment, ["CODEX_HOME": "/demo/codex"])
        XCTAssertNil(AgentProcess.parse(bytes.prefix(8)))
    }

    func testRestoredEnvironmentPreservesCompoundTemplatesAndShellFunctions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-exist")
        let id = "literal'; touch \(marker.path); echo '"
        let session = AgentSession(kind: .codex, sessionID: id, cwd: directory.path, flags: [],
                                   environment: ["CODEX_HOME": "/demo/custom home", "OPENAI_API_KEY": "must-not-export"])
        let command = session.resumeCommand(template: "cd {cwd} && capture {id}")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", "capture() { print -r -- \"$CODEX_HOME\"; print -r -- \"$1\"; print -r -- \"${OPENAI_API_KEY-unset}\"; }; " + command]
        shell.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "/demo/custom home\n\(id)\nunset\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOmpUsesTheExactTTYPointerRatherThanNewestFileInFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent.appendingPathComponent("terminal-sessions"), withIntermediateDirectories: true)
        let id = "38ca8094-12d0-4f5b-86c3-0ac9b02e21bb"
        let selected = root.appendingPathComponent("selected.jsonl")
        let newer = root.appendingPathComponent("newer.jsonl")
        try Data(("{\"type\":\"title\",\"title\":\"Demo\"}\n{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\",\"cwd\":\"/demo\"}\n").utf8).write(to: selected)
        try Data("{\"type\":\"session\",\"id\":\"550e8400-e29b-41d4-a716-446655440000\"}\n".utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: newer.path)
        let pointer = agent.appendingPathComponent("terminal-sessions/ttys999")
        try Data("\(root.path)\nselected.jsonl\n".utf8).write(to: pointer)
        let process = AgentProcess(identity: .init(pid: 4242, seconds: 1, microseconds: 0),
                                   invocation: try XCTUnwrap(AgentInvocation(["bun", "omp"])),
                                   environment: ["HOME": root.path, "PI_CODING_AGENT_DIR": agent.path])
        let result = try XCTUnwrap(OmpSessions.session(process: process, ttyName: "/dev/ttys999"))
        XCTAssertEqual(result.sessionID, id)
        XCTAssertEqual(result.sessionFile, selected.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: pointer.path)
        XCTAssertNil(OmpSessions.session(process: process, ttyName: "/dev/ttys999"))
    }

    func testNeverPersistedOmpStartsTheHarnessButDeletedHistoryDoesNotStartFresh() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("new session.jsonl")
        var session = AgentSession(kind: .omp, sessionID: UUID().uuidString, cwd: root.path, flags: [],
                                   sessionFile: journal.path, unpersisted: true)
        XCTAssertEqual(session.resumeCommand, "omp")
        try JSONSerialization.data(withJSONObject: ["type": "session", "version": 3, "id": session.sessionID, "cwd": root.path]).write(to: journal)
        XCTAssertTrue(session.resumeCommand.contains("--resume"))
        try FileManager.default.removeItem(at: journal)
        session.unpersisted = nil
        XCTAssertTrue(session.resumeCommand.contains("--resume"))
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.sessionFile, journal.path)
        XCTAssertNil(decoded.unpersisted)
    }

    func testRegistrationRejectsForeignTTYTokenAndStalePIDFile() throws {
        for kind in [AgentSession.Kind.omp, .opencode] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            child.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-c", "exec -a \(kind.rawValue) /bin/sleep 10"]
            child.currentDirectoryURL = root
            child.environment = ProcessInfo.processInfo.environment.merging(["ZDOTDIR": root.path]) { _, new in new }
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            var ownedPID: pid_t?
            defer {
                if let ownedPID { kill(ownedPID, SIGTERM) }
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }
            var fixture: (AgentProcess, dev_t)?
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, fixture == nil {
                let tree = ProcessTree()
                var children = tree.children[child.processIdentifier] ?? []
                while let pid = children.popLast() {
                    if let process = AgentProcess.read(pid), process.invocation.kind == kind,
                       let dev = tree.byTTY.first(where: { $0.value.contains(pid) })?.key {
                        fixture = (process, dev)
                        ownedPID = pid
                        break
                    }
                    children += tree.children[pid] ?? []
                }
                if fixture == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            let (process, dev) = try XCTUnwrap(fixture)
            let id = kind == .omp ? "38ca8094-12d0-4f5b-86c3-0ac9b02e21bb" : "ses_fixture"
            var request: [String: Any] = ["kind": kind.rawValue, "pid": Int(process.identity.pid), "token": "current-pane",
                                         "sessionID": id, "sessionFile": root.appendingPathComponent("session.jsonl").path]
            XCTAssertNotNil(AgentRegistration.accept(request, token: "current-pane", onTTY: dev))
            XCTAssertNil(AgentRegistration.accept(request, token: "old-pane", onTTY: dev))
            XCTAssertNil(AgentRegistration.accept(request, token: "current-pane", onTTY: dev_t.max))
            let file = root.appendingPathComponent("\(process.identity.pid).json")
            try JSONSerialization.data(withJSONObject: request).write(to: file)
            XCTAssertNotNil(AgentRegistration.load(directory: root, process: process, token: "current-pane", onTTY: dev, tree: ProcessTree()))
            let completed = expectation(description: "Ancestry traversal stops before the kernel's self-parent")
            DispatchQueue.global().async {
                let snapshot = Agents.snapshot(onTTY: dev, tree: ProcessTree(), foregroundPID: process.identity.pid,
                                               directory: root, token: "current-pane", ttyName: "/dev/fixture")
                XCTAssertEqual(snapshot.process?.identity, process.identity)
                XCTAssertEqual(snapshot.session?.sessionID, id)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
            XCTAssertNil(AgentRegistration.load(directory: root, process: process, token: "current-pane", onTTY: dev, tree: ProcessTree()))
            request["sessionID"] = NSNull()
            let home = try XCTUnwrap(AgentRegistration.accept(request, token: "current-pane", onTTY: dev))
            if kind == .opencode {
                let fresh = try XCTUnwrap(home.session)
                XCTAssertEqual(fresh.sessionID, "")
                XCTAssertEqual(fresh.unpersisted, true)
                XCTAssertFalse(fresh.resumeCommand.contains(" --session "))
                request["inactive"] = true
                XCTAssertNil(try XCTUnwrap(AgentRegistration.accept(request, token: "current-pane", onTTY: dev)).session)
            } else {
                XCTAssertNil(home.session)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helium-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
