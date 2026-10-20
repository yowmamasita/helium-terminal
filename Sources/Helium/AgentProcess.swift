import Darwin
import Foundation

struct AgentProcess {
    struct Identity: Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }

    let identity: Identity
    let invocation: AgentInvocation
    let environment: [String: String]
    var command: [String]?

    struct Arguments {
        let argv: [String]
        var environment: [String: String]
        let executablePath: String
        let searchPath: String?
        let workingDirectory: String?
    }

    static func read(_ pid: pid_t) -> AgentProcess? {
        guard let identity = identity(pid), var data = arguments(pid),
              let invocation = AgentInvocation(data.argv), invocation.interactive else { return nil }
        if data.environment["HOME"] == NSHomeDirectory() { data.environment.removeValue(forKey: "HOME") }
        return AgentProcess(identity: identity, invocation: invocation, environment: data.environment,
                            command: launchCommand(data))
    }

    static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    /// KERN_PROCARGS2: argc, exec path, padding, argv, then the original environment.
    static func arguments(_ pid: pid_t) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(buffer.prefix(size))
    }

    static func parse(_ buffer: ArraySlice<UInt8>) -> Arguments? {
        guard buffer.count > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= buffer.count else { return nil }
        var i = buffer.startIndex + 4
        while i < buffer.endIndex, buffer[i] != 0 { i += 1 }
        let executablePath = String(decoding: buffer[(buffer.startIndex + 4)..<i], as: UTF8.self)
        while i < buffer.endIndex, buffer[i] == 0 { i += 1 }
        func string() -> String {
            let start = i
            while i < buffer.endIndex, buffer[i] != 0 { i += 1 }
            let result = String(decoding: buffer[start..<i], as: UTF8.self)
            if i < buffer.endIndex { i += 1 }
            return result
        }
        var argv: [String] = []
        for _ in 0..<argc {
            guard i < buffer.endIndex else { return nil }
            argv.append(string())
        }
        var environment: [String: String] = [:]
        var searchPath: String?
        var workingDirectory: String?
        while i < buffer.endIndex {
            let entry = string()
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            let value = entry[entry.index(after: separator)...]
            if key == "PATH" { searchPath = String(value) }
            if key == "PWD" { workingDirectory = String(value) }
            if AgentInvocation.environmentKeys.contains(key) {
                environment[key] = String(value)
            }
        }
        return Arguments(argv: argv, environment: environment, executablePath: executablePath,
                         searchPath: searchPath, workingDirectory: workingDirectory)
    }

    static func launchCommand(_ data: Arguments) -> [String]? {
        func absolute(_ value: String, script: Bool = false) -> String? {
            if value.hasPrefix("/") { return value }
            if let cwd = data.workingDirectory {
                let local = URL(fileURLWithPath: cwd).appendingPathComponent(value).standardizedFileURL.path
                if value.contains("/") || script && FileManager.default.fileExists(atPath: local) { return local }
            }
            for entry in data.searchPath?.split(separator: ":", omittingEmptySubsequences: false) ?? [] {
                var directory = String(entry)
                if !directory.hasPrefix("/") {
                    guard let cwd = data.workingDirectory else { continue }
                    directory = URL(fileURLWithPath: cwd).appendingPathComponent(directory).path
                }
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(value).path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
        guard let first = data.argv.first else { return nil }
        let program = absolute(first) ?? data.executablePath
        guard program.hasPrefix("/") else { return nil }
        if ["bun", "node", "nodejs"].contains((first as NSString).lastPathComponent) {
            guard data.argv.count > 1, let script = absolute(data.argv[1], script: true) else { return nil }
            return [program, script]
        }
        return [program]
    }
}

/// Owned by one pane. PID reuse, exec into a different program, and tty reuse invalidate it.
struct AgentRegistration {
    let identity: AgentProcess.Identity
    let session: AgentSession?

    static func load(directory: URL, process: AgentProcess, token: String, onTTY dev: dev_t,
                     tree: ProcessTree) -> AgentRegistration? {
        let url = directory.appendingPathComponent("\(process.identity.pid).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              modified.timeIntervalSince1970 >= Double(process.identity.seconds) + Double(process.identity.microseconds) / 1_000_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), data.count < 64 * 1024,
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let registration = accept(request, token: token, onTTY: dev, tree: tree),
              registration.identity == process.identity else { return nil }
        return registration
    }

    static func accept(_ request: [String: Any], token: String, onTTY dev: dev_t,
                       tree: ProcessTree = ProcessTree()) -> AgentRegistration? {
        guard request["token"] as? String == token,
              let number = request["pid"] as? Int, number > 1, number <= Int(Int32.max),
              let rawKind = request["kind"] as? String, let kind = AgentSession.Kind(rawValue: rawKind),
              kind == .omp || kind == .opencode,
              tree.processes(onTTYs: [dev]).contains(pid_t(number)),
              let process = AgentProcess.read(pid_t(number)), process.invocation.kind == kind,
              request["sessionID"] != nil else { return nil }
        if request["sessionID"] is NSNull {
            let fresh = kind == .opencode && request["inactive"] as? Bool != true
                ? AgentSession(kind: kind, sessionID: "", cwd: Metadata.cwd(of: process.identity.pid),
                               flags: AgentSession.resumableFlags(kind, process.invocation.arguments),
                               environment: process.environment.isEmpty ? nil : process.environment,
                               unpersisted: true, command: process.command) : nil
            return AgentRegistration(identity: process.identity, session: fresh)
        }
        guard let id = request["sessionID"] as? String, validSessionID(id, kind: kind) else { return nil }
        let file = request["sessionFile"] as? String
        if kind == .omp {
            guard let file, file.hasPrefix("/"), !file.utf8.contains(0) else { return nil }
        }
        let cwd = (request["cwd"] as? String).flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
        let session = AgentSession(kind: kind, sessionID: id, cwd: cwd ?? Metadata.cwd(of: process.identity.pid),
                                   flags: AgentSession.resumableFlags(kind, process.invocation.arguments),
                                   sessionFile: file, environment: process.environment.isEmpty ? nil : process.environment,
                                   command: process.command)
        return AgentRegistration(identity: process.identity, session: session)
    }

    static func validSessionID(_ id: String, kind: AgentSession.Kind) -> Bool {
        if kind != .opencode { return UUID(uuidString: id) != nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return id.hasPrefix("ses_") && id.count > 4 && id.count <= 256 && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}
