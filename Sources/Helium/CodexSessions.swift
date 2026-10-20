import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Compatibility with Codex rust-v0.163.0 (83086188ae0614bd882818ff1aa23f3194962012).
/// Only identity metadata is read, never rollout contents or thread/read responses.
enum CodexSessions {
    struct Selection {
        let sessionID: String
        let cwd: String?
        let sessionFile: String?
        var unpersisted = false
    }

    private static let spinners = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

    // tui/src/chatwidget/{status_surfaces,thread_title_status}.rs: app-name is literal
    // "codex"; thread-id is 29 UUID characters + "...", optionally followed by a spinner.
    // While busy, Codex joins the spinner and subsequent components with spaces, not pipes.
    static func prefix(in title: String) -> String? {
        guard title.hasPrefix("codex | ") else { return nil }
        let body = title.dropFirst(8)
        let truncated = body.prefix(32).hasSuffix("...")
        let identity = String(body.prefix(truncated ? 29 : 36))
        guard identity.utf8.count == (truncated ? 29 : 36), validPrefix(identity) else { return nil }
        let suffix = body.dropFirst(truncated ? 32 : 36)
        if !suffix.isEmpty && !suffix.hasPrefix(" | ") {
            guard suffix.first == " ", let spinner = suffix.dropFirst().first,
                  spinners.contains(spinner) else { return nil }
            let following = suffix.dropFirst(2)
            guard following.isEmpty || following.first == " " else { return nil }
        }
        return identity
    }

    private static func validPrefix(_ value: String) -> Bool {
        guard value.utf8.count == 29 || value.utf8.count == 36 else { return false }
        return value.utf8.enumerated().allSatisfy { index, byte in
            if [8, 13, 18, 23].contains(index) { return byte == 45 }
            return (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    static func resolve(prefix: String, home: URL, processPID: pid_t) -> Selection? {
        resolve(requests: [(prefix, processPID)], home: home)[processPID]
    }

    /// One daemon query per home/poll, shared by all its panes. Revalidate even an unchanged
    /// prefix: a newly loaded thread could otherwise introduce a hidden-suffix collision.
    static func resolve(requests: [(prefix: String, processPID: pid_t)], home: URL) -> [pid_t: Selection] {
        let requests = requests.filter { validPrefix($0.prefix) }
        guard !requests.isEmpty else { return [:] }
        var persistedRows: [String: [Selection]] = [:]
        let database = home.appendingPathComponent("state_5.sqlite")
        if FileManager.default.fileExists(atPath: database.path) {
            for prefix in Set(requests.map(\.prefix)) {
                guard let rows = persisted(prefix: prefix, database: database) else { return [:] }
                persistedRows[prefix] = rows
            }
        }
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        var loadedIDs: [String] = []
        if FileManager.default.fileExists(atPath: socket.path) {
            guard let ids = loaded(socket: socket.path) else { return [:] }
            loadedIDs = ids
        }
        var result: [pid_t: Selection] = [:]
        for request in requests {
            var matches: [String: Selection] = [:]
            for row in persistedRows[request.prefix] ?? [] { matches[row.sessionID] = row }
            for id in loadedIDs where id.hasPrefix(request.prefix) && matches[id] == nil {
                matches[id] = Selection(sessionID: id, cwd: nil, sessionFile: nil, unpersisted: true)
            }
            guard let files = rolloutFiles(pid: request.processPID, home: home) else { continue }
            for row in files where row.sessionID.hasPrefix(request.prefix) && matches[row.sessionID]?.unpersisted != false {
                matches[row.sessionID] = row
            }
            if matches.count == 1 { result[request.processPID] = matches.values.first }
        }
        return result
    }

    static func displayTitle(_ raw: String, prefix: String?) -> String {
        guard let prefix else { return raw }
        let suffix = raw.dropFirst(8 + (prefix.utf8.count == 29 ? 32 : 36))
        var visible = suffix.dropFirst(suffix.hasPrefix(" | ") ? 3 : 1)
        // thread-id carries its own status. Keep an explicitly configured spinner, not both.
        if let first = visible.first, spinners.contains(first), visible.dropFirst().first == " ",
           let next = visible.dropFirst(2).first, spinners.contains(next) {
            visible = visible.dropFirst(2)
        }
        return visible.isEmpty ? "Codex" : String(visible)
    }

    /// Recheck at launch: an empty thread may have acquired history since the last saved snapshot.
    /// Unknown metadata must not turn a previously selected conversation into a fresh one.
    static func hasPersistedSession(_ id: String, home: URL) -> Bool? {
        guard id.count == 36, validPrefix(id) else { return nil }
        let database = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return false }
        return persisted(prefix: id, database: database, busyTimeout: 0).map { $0.contains { $0.sessionID == id } }
    }

    // state/migrations/0001_threads.sql: id TEXT PRIMARY KEY, cwd, rollout_path.
    // A binary range uses the primary-key index, unlike SQLite's default case-insensitive LIKE.
    private static func persisted(prefix: String, database: URL, busyTimeout: Int32 = 40) -> [Selection]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, busyTimeout)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 64 * 1024)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, cwd, rollout_path FROM threads WHERE id >= ?1 AND id < ?2 ORDER BY id LIMIT 2", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, prefix, -1, transient)
        sqlite3_bind_text(statement, 2, prefix + "g", -1, transient)
        var rows: [Selection] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                func text(_ column: Int32) -> String? {
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                }
                guard let id = text(0), id.count == 36, validPrefix(id), id.hasPrefix(prefix) else { return nil }
                rows.append(Selection(sessionID: id, cwd: text(1), sessionFile: text(2)))
            default: return nil
            }
        }
    }

    private static func rolloutFiles(pid: pid_t, home: URL) -> [Selection]? {
        guard pid > 0 else { return [] }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes <= 1024 * 1024 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = bytes + Int32(stride * 32)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(capacity) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard got > 0, got < capacity else { return nil }
        let root = home.resolvingSymlinksInPath().appendingPathComponent("sessions").path + "/"
        var rows: [Selection] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let name = url.lastPathComponent
            guard url.path.hasPrefix(root), name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let id = String(name.dropLast(6).suffix(36))
            guard id.count == 36, validPrefix(id) else { continue }
            rows.append(Selection(sessionID: id, cwd: nil, sessionFile: path))
        }
        return rows
    }

    // app-server-daemon/src/client.rs: HTTP Upgrade over UnixStream, initialize then
    // initialized. schema/typescript/v2/ThreadLoadedList{Params,Response}.ts: cursor paging.
    private static func loaded(socket path: String) -> [String]? {
        guard let connection = ControlConnection(path: path) else { return nil }
        defer { connection.close() }
        guard connection.upgrade(),
              connection.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "helium_terminal", "version": "1"],
                "capabilities": ["experimentalApi": false]
              ]) != nil,
              connection.send(["method": "initialized"]) else { return nil }
        var cursor: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        for page in 0..<128 {
            var params: [String: Any] = ["limit": 256]
            if let cursor { params["cursor"] = cursor }
            guard let result = connection.request(id: page + 2, method: "thread/loaded/list", params: params),
                  let data = result["data"] as? [String], data.count <= 256,
                  result.keys.contains("nextCursor") else { return nil }
            for id in data {
                guard id.count == 36, validPrefix(id) else { return nil }
                ids.insert(id)
            }
            if result["nextCursor"] is NSNull { return Array(ids) }
            guard let next = result["nextCursor"] as? String, next.utf8.count <= 4096,
                  cursors.insert(next).inserted else { return nil }
            cursor = next
        }
        return nil // Never accept a partial page set.
    }

    /// Small synchronous RFC 6455 client. One total deadline and byte budget include all
    /// notifications, control frames and pages, so a daemon cannot monopolize the poller.
    private final class ControlConnection {
        private let fd: Int32
        private let deadline = DispatchTime.now().uptimeNanoseconds + 750_000_000
        private var remaining = 4 * 1024 * 1024

        init?(path: String) {
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes + [0])
            }
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            fd = descriptor
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); return nil }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS, ready(POLLOUT) else { Darwin.close(fd); return nil }
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { Darwin.close(fd); return nil }
            }
        }

        func close() { Darwin.close(fd) }

        private func ready(_ events: Int32) -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            return poll(&descriptor, 1, Int32((deadline - now) / 1_000_000 + 1)) > 0
                && Int32(descriptor.revents) & events != 0
        }

        private func writeBytes(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                guard ready(POLLOUT) else { return false }
                let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }

        private func readBytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= remaining else { return nil }
            remaining -= count
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                guard ready(POLLIN) else { return nil }
                let got = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
                guard got > 0 else { return nil }
                offset += got
            }
            return bytes
        }

        func upgrade() -> Bool {
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            guard writeBytes(Array(request.utf8)) else { return false }
            var response: [UInt8] = []
            while response.count < 8192 {
                guard let byte = readBytes(1) else { return false }
                response += byte
                if response.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
            }
            guard response.suffix(4).elementsEqual([13, 10, 13, 10]),
                  let text = String(bytes: response, encoding: .utf8) else { return false }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.first?.split(separator: " ").dropFirst().first == "101" else { return false }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            return headers["sec-websocket-accept"] == accept
                && headers["upgrade"]?.lowercased() == "websocket"
                && headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true
        }

        private func frame(_ payload: [UInt8], opcode: UInt8) -> Bool {
            guard payload.count <= 65535 else { return false }
            var bytes: [UInt8] = [0x80 | opcode]
            if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) }
            else { bytes += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 255)] }
            let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
            bytes += mask
            bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            return writeBytes(bytes)
        }

        func send(_ object: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return frame(Array(data), opcode: 1)
        }

        private func message() -> [String: Any]? {
            var message: [UInt8] = []
            var started = false
            while true {
                guard let header = readBytes(2), header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { return nil }
                let final = header[0] & 0x80 != 0
                let opcode = header[0] & 15
                var size = Int(header[1] & 127)
                if size == 126 {
                    guard let length = readBytes(2) else { return nil }
                    size = Int(length[0]) * 256 + Int(length[1])
                } else if size == 127 {
                    guard let length = readBytes(8), length.prefix(5).allSatisfy({ $0 == 0 }) else { return nil }
                    size = Int(length[5]) * 65536 + Int(length[6]) * 256 + Int(length[7])
                }
                guard size <= 1024 * 1024, message.count + size <= 1024 * 1024,
                      let payload = readBytes(size) else { return nil }
                if opcode == 9 {
                    guard final, size <= 125, frame(payload, opcode: 10) else { return nil }
                    continue
                }
                if opcode == 10 { guard final, size <= 125 else { return nil }; continue }
                guard (opcode == 1 && !started) || (opcode == 0 && started) else { return nil }
                started = true
                message += payload
                if final {
                    return (try? JSONSerialization.jsonObject(with: Data(message))) as? [String: Any]
                }
            }
        }

        func request(id: Int, method: String, params: [String: Any]) -> [String: Any]? {
            guard send(["id": id, "method": method, "params": params]) else { return nil }
            for _ in 0..<256 {
                guard let message = message() else { return nil }
                if (message["id"] as? Int) == id { return message["result"] as? [String: Any] }
            }
            return nil
        }
    }
}
