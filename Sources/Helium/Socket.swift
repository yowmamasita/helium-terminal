import AppKit

/// Unix socket API: one JSON object per line in, one JSON object per line out.
/// Only the current user can connect (socket file is 0600).
final class SocketServer {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["HELIUM_SOCKET"], !p.isEmpty { return p }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/helium-terminal")
        return dir.appendingPathComponent("helium.sock").path
    }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "helium.socket")
    private let handler: ([String: Any]) -> [String: Any]

    init(handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    func start() throws {
        let path = Self.path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw POSIXError(.EIO) }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(Self.path)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // A stuck client must not hold up the queue.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A), data.count < 1 << 20 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let reply: [String: Any]
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            reply = DispatchQueue.main.sync { handler(obj) }
        } else {
            reply = ["ok": false, "error": "expected one JSON object per line"]
        }
        var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}

/// `helium <command>`: turns argv into a request and prints the reply.
enum CLI {
    static let usage = """
    usage: helium <command> [options]

      list                                   tabs, panes and their metadata
      new-tab [--cwd DIR] [--command CMD]    open a tab
      select <tab>                           switch to a tab
      split [right|down] [--pane ID]         split a pane
      focus <pane>                           focus a pane
      send [--pane ID] <text>                type text ("\\n" presses Return)
      notify [--pane ID] [--title T] <body>  ring a pane and set its tab's notification
      close [--pane ID]                      close a pane

    --pane defaults to $HELIUM_PANE (the pane the command runs in), else the focused pane.
    """

    static func run(_ args: [String]) -> Int32 {
        guard let cmd = args.first, !["help", "--help", "-h"].contains(cmd) else {
            print(usage)
            return 0
        }
        var req: [String: Any] = ["cmd": cmd]
        var positional: [String] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--"), i + 1 < args.count {
                req[String(a.dropFirst(2))] = args[i + 1]
                i += 2
            } else {
                positional.append(a)
                i += 1
            }
        }
        if !positional.isEmpty {
            // Shells pass "\n" literally; turn it into a real newline for `send`.
            req["arg"] = positional.joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
        }
        if req["pane"] == nil, let p = ProcessInfo.processInfo.environment["HELIUM_PANE"] { req["pane"] = p }

        do {
            let reply = try request(req)
            FileHandle.standardOutput.write(reply)
            let obj = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            return obj?["ok"] as? Bool == true ? 0 : 1
        } catch {
            FileHandle.standardError.write("helium: \(error.localizedDescription) (is Helium running?)\n".data(using: .utf8)!)
            return 2
        }
    }

    private static func request(_ req: [String: Any]) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = SocketServer.path
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        return reply
    }
}
