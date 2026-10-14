import AppKit
import Darwin

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
    private var listening = false // only then is the socket file ours to delete
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var ownedPath: String?
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private let io = DispatchQueue(label: "helium.socket")
    private let clients = DispatchQueue(label: "helium.socket.clients", attributes: .concurrent)
    private let clientSlots = DispatchSemaphore(value: maxInFlightClients)
    private let handler: ([String: Any]) -> [String: Any]

    static let maxInFlightClients = 32

    init(handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    func start() throws {
        guard !listening else { throw POSIXError(.EALREADY) }
        let path = Self.path
        var address = try Self.address(for: path)
        socketIdentity = nil
        ownedPath = nil
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // The lock closes the check-then-unlink race between two Helium instances.
        let lockPath = path + ".lock"
        let lock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { if !listening { close(lock) } }
        var lockStat = stat()
        guard fstat(lock, &lockStat) == 0,
              (lockStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockStat.st_uid == getuid(),
              fchmod(lock, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            throw POSIXError(code == .EWOULDBLOCK ? .EADDRINUSE : code)
        }
        // Never remove a regular file, directory, symlink, or another live socket.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
                throw POSIXError(.EADDRINUSE)
            }
            guard existing.st_uid == getuid() else {
                throw POSIXError(.EADDRINUSE)
            }
            if Self.isLive(path) { throw POSIXError(.EADDRINUSE) }
            guard unlink(path) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var bound = false
        defer {
            if !bound {
                close(fd)
                fd = -1
                if socketIdentity != nil { unlinkOwned(path) }
            }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var boundStat = stat()
        guard lstat(path, &boundStat) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        socketIdentity = (boundStat.st_dev, boundStat.st_ino)
        guard chmod(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Self.setNonblocking(fd) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        bound = true
        listening = true
        lockFD = lock
        ownedPath = path

        let listenerFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: io)
        src.setEventHandler { [weak self] in
            self?.accept(listenerFD)
        }
        src.resume()
        source = src
    }

    func stop() {
        guard listening else { return } // never started, so the socket file isn't ours
        listening = false
        let socketFD = fd
        fd = -1
        let src = source
        source = nil
        if let src {
            src.setEventHandler {}
            src.setCancelHandler {
                close(socketFD)
            }
            src.cancel()
        } else {
            close(socketFD)
        }
        if let path = ownedPath { unlinkOwned(path) }
        ownedPath = nil
        socketIdentity = nil
        let lock = lockFD
        lockFD = -1
        if lock >= 0 {
            flock(lock, LOCK_UN)
            close(lock)
        }
    }

    private static func isLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // fail closed rather than unlinking a live endpoint
        defer { close(fd) }
        guard var addr = try? address(for: path) else { return true }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return true }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return true }
        return ![ECONNREFUSED, ENOENT].contains(errno)
    }

    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard !path.isEmpty, !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        return addr
    }

    private func unlinkOwned(_ path: String) {
        guard let identity = socketIdentity else { return }
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == identity.dev, current.st_ino == identity.ino else { return }
        _ = unlink(path)
    }

    @discardableResult static func noSigPipe(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    @discardableResult static func setNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func timeout(_ fd: Int32) {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func ioDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    }

    fileprivate static func waitForIO(_ fd: Int32, events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw POSIXError(.ETIMEDOUT) }
            let remaining = deadline - now
            let milliseconds = Int32(min(UInt64(Int32.max), max(UInt64(1), (remaining + 999_999) / 1_000_000)))
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&pfd, 1, milliseconds)
            if result > 0 {
                if pfd.revents & Int16(POLLNVAL | POLLERR) != 0 { throw POSIXError(.EIO) }
                if pfd.revents & (events | Int16(POLLHUP)) != 0 { return }
            } else if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            } else {
                throw POSIXError(.ETIMEDOUT)
            }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        guard setNonblocking(fd) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let deadline = ioDeadline()
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitForIO(fd, events: Int16(POLLOUT), until: deadline)
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func accept(_ listenerFD: Int32) {
        while true {
            let client = Darwin.accept(listenerFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard Self.setNonblocking(client), clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            let slots = clientSlots
            clients.async { [weak self] in
                defer { slots.signal() }
                guard let self else { close(client); return }
                self.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }
        // A stuck client must not hold up the queue.
        guard Self.noSigPipe(client) else { return }
        Self.timeout(client)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Self.ioDeadline()
        var timedOut = false
        var tooLarge = false
        while !data.contains(0x0A), data.count < 1 << 20 {
            do { try Self.waitForIO(client, events: Int16(POLLIN), until: deadline) }
            catch let error as POSIXError where error.code == .ETIMEDOUT { timedOut = true; break }
            catch { break }
            let n = read(client, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            data.append(contentsOf: buf[0..<n])
        }
        tooLarge = if let nl = data.firstIndex(of: 0x0A) {
            nl >= 1 << 20
        } else {
            data.count >= 1 << 20
        }
        if data.isEmpty && !timedOut { return } // e.g. a liveness probe that connected and left
        if tooLarge {
            data = Data()
        } else if let nl = data.firstIndex(of: 0x0A) {
            data = data[..<nl] // one request per connection
        }
        let reply: [String: Any]
        if tooLarge {
            reply = ["ok": false, "error": "request too large"]
        } else if timedOut {
            reply = ["ok": false, "error": "request timed out"]
        } else if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            reply = DispatchQueue.main.sync { handler(obj) }
        } else {
            reply = ["ok": false, "error": "expected one JSON object per line"]
        }
        var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        out.append(0x0A)
        try? Self.writeAll(client, out)
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
    A pane that no longer exists is an error, never the focused pane.
    """

    static func run(_ args: [String]) -> Int32 {
        guard let req = requestArguments(args) else {
            print(usage)
            return 0
        }

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

    /// Builds the socket request without contacting the app, so argument rules stay testable.
    static func requestArguments(_ args: [String]) -> [String: Any]? {
        guard let cmd = args.first, !["help", "--help", "-h"].contains(cmd) else { return nil }
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
            let value = positional.joined(separator: " ")
            // Shells pass "\n" literally; only `send` treats it as a Return key.
            req["arg"] = cmd == "send" ? value.replacingOccurrences(of: "\\n", with: "\n") : value
        }
        if req["pane"] == nil, let p = ProcessInfo.processInfo.environment["HELIUM_PANE"] { req["pane"] = p }
        return req
    }

    private static func request(_ req: [String: Any]) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard SocketServer.noSigPipe(fd) else { throw POSIXError(.EIO) }
        SocketServer.timeout(fd)
        var addr = try SocketServer.address(for: SocketServer.path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        try SocketServer.writeAll(fd, data)

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = SocketServer.ioDeadline()
        while true {
            try SocketServer.waitForIO(fd, events: Int16(POLLIN), until: deadline)
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard reply.count + n <= 1 << 20 else { throw POSIXError(.EFBIG) }
            reply.append(contentsOf: buf[0..<n])
        }
        return reply
    }
}
