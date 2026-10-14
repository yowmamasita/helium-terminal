import Foundation
import Darwin
import XCTest
@testable import helium_terminal

final class SocketTests: XCTestCase {
    private var directory: URL!

    private func connect(to path: String) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.EIO) }
        var address = try SocketServer.address(for: path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(client)
            throw POSIXError(code)
        }
        return client
    }

    private func readLine(from fd: Int32, timeout: Int32 = 4_000) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !data.contains(0x0A) {
            var pollfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollfd, 1, timeout) > 0 else { throw POSIXError(.ETIMEDOUT) }
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/helium-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("HELIUM_SOCKET")
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testCLIOnlyDecodesLiteralNewlinesForSend() {
        let notify = CLI.requestArguments(["notify", "line\\nnext"])
        XCTAssertEqual(notify?["arg"] as? String, "line\\nnext")
        let send = CLI.requestArguments(["send", "line\\nnext"])
        XCTAssertEqual(send?["arg"] as? String, "line\nnext")
        XCTAssertNil(CLI.requestArguments(["--help"]))
    }

    func testSocketNeverRemovesAnUnrelatedFile() throws {
        let path = directory.appendingPathComponent("helium.sock")
        let contents = Data("keep me".utf8)
        try contents.write(to: path)
        setenv("HELIUM_SOCKET", path.path, 1)
        let server = SocketServer { _ in ["ok": true] }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try Data(contentsOf: path), contents)
    }

    func testSocketOwnershipSurvivesSecondStartAndAllowsRestart() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let first = SocketServer { _ in ["ok": true] }
        try first.start()
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let second = SocketServer { _ in ["ok": true] }
        XCTAssertThrowsError(try second.start())
        first.stop()

        let restarted = SocketServer { _ in ["ok": true] }
        try restarted.start()
        restarted.stop()
    }

    func testSocketReadDeadlineStopsDrippingClient() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let server = SocketServer { _ in ["ok": true] }
        try server.start()
        defer { server.stop() }

        let done = expectation(description: "dripping client receives timeout")
        let lock = NSLock()
        var response = Data()
        var elapsed = 0.0
        DispatchQueue.global().async {
            let started = Date()
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            guard client >= 0 else { done.fulfill(); return }
            defer { close(client) }
            SocketServer.noSigPipe(client)
            SocketServer.timeout(client)
            guard var address = try? SocketServer.address(for: path) else { done.fulfill(); return }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { done.fulfill(); return }

            // No newline: each byte arrives within the per-read timeout, but not within
            // the request's two-second overall deadline.
            for byte in Data(#"{"cmd":"ping"}"#.utf8) {
                var byte = byte
                _ = Darwin.write(client, &byte, 1)
                usleep(100_000)
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            lock.lock()
            if count > 0 { response = Data(buffer[0..<count]) }
            elapsed = Date().timeIntervalSince(started)
            lock.unlock()
            done.fulfill()
        }

        wait(for: [done], timeout: 4)
        lock.lock()
        let result = response
        let duration = elapsed
        lock.unlock()
        XCTAssertLessThan(duration, 3, "a slow-drip client must not extend the request deadline")
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("request timed out"))
    }

    func testSocketPathMustFitUnixAddress() {
        let path = String(repeating: "x", count: 4096)
        XCTAssertThrowsError(try SocketServer.address(for: path))
        XCTAssertThrowsError(try SocketServer.address(for: "helium\0socket"))
    }

    func testSocketRoundTripSupportsLargeCompleteReply() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let value = String(repeating: "payload,\"quoted\" ", count: 30_000)
        let server = SocketServer { request in
            ["ok": true, "value": request["value"] as? String ?? ""]
        }
        try server.start()
        defer { server.stop() }

        let done = expectation(description: "large round trip")
        let lock = NSLock()
        var response = Data()
        var failure: Error?
        DispatchQueue.global().async {
            do {
                let client = try self.connect(to: path)
                defer { close(client) }
                let request = try JSONSerialization.data(withJSONObject: ["cmd": "echo", "value": value]) + Data([0x0A])
                try SocketServer.writeAll(client, request)
                let reply = try self.readLine(from: client)
                lock.lock()
                response = reply
                lock.unlock()
            } catch {
                lock.lock()
                failure = error
                lock.unlock()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        lock.lock()
        let result = response
        let error = failure
        lock.unlock()
        XCTAssertNil(error)
        let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["value"] as? String, value)
    }

    func testSocketRejectsOversizedLineWhenNewlineIsInOvershootChunk() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let server = SocketServer { _ in XCTFail("oversized request reached the handler"); return ["ok": true] }
        try server.start()
        defer { server.stop() }

        let client = try connect(to: path)
        defer { close(client) }
        var request = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) + 32)
        request.append(0x0A)
        try SocketServer.writeAll(client, request)
        let reply = try readLine(from: client)
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("request too large"))
    }

    func testSocketWriteFailsClosedPeerWithoutSIGPIPE() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]) }
        XCTAssertTrue(SocketServer.noSigPipe(pair[0]))
        close(pair[1])
        XCTAssertThrowsError(try SocketServer.writeAll(pair[0], Data(repeating: 0x61, count: 64)))
    }

    func testSocketWriteDeadlineRetriesWouldBlock() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        XCTAssertTrue(SocketServer.setNonblocking(pair[0]))
        let chunk = [UInt8](repeating: 0x61, count: 65_536)
        while true {
            let written = chunk.withUnsafeBytes { bytes in
                Darwin.write(pair[0], bytes.baseAddress!, bytes.count)
            }
            if written > 0 { continue }
            if written == 0 { break }
            XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
            break
        }

        let started = Date()
        var timeout = false
        XCTAssertThrowsError(try SocketServer.writeAll(pair[0], Data([0x62]))) { error in
            timeout = (error as? POSIXError)?.code == .ETIMEDOUT
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(timeout)
        XCTAssertGreaterThanOrEqual(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 3)
    }

    func testSocketBoundsStuckClients() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let server = SocketServer { _ in XCTFail("stuck request reached the handler"); return ["ok": true] }
        try server.start()
        defer { server.stop() }

        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<(SocketServer.maxInFlightClients + 4) {
            if let client = try? connect(to: path) {
                clients.append(client)
                _ = SocketServer.setNonblocking(client)
                var byte: UInt8 = 0x7B
                _ = Darwin.write(client, &byte, 1) // keep accepted handlers occupied
            }
        }
        usleep(250_000)
        var closed = 0
        for client in clients {
            var pfd = pollfd(fd: client, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&pfd, 1, 100) > 0, pfd.revents & Int16(POLLHUP | POLLERR) != 0 { closed += 1 }
        }
        XCTAssertGreaterThanOrEqual(closed, 4, "connections beyond the in-flight bound should be closed")
    }

    func testSocketStopDoesNotWaitForClientHandlers() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        setenv("HELIUM_SOCKET", path, 1)
        let server = SocketServer { _ in XCTFail("stuck request reached the handler"); return ["ok": true] }
        try server.start()
        let client = try connect(to: path)
        defer { close(client) }
        var byte: UInt8 = 0x7B
        _ = Darwin.write(client, &byte, 1)
        usleep(50_000)
        let started = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testSocketLockRejectsSymlink() throws {
        let path = directory.appendingPathComponent("helium.sock").path
        let target = directory.appendingPathComponent("lock-target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: path + ".lock", withDestinationPath: target.path)
        setenv("HELIUM_SOCKET", path, 1)
        let server = SocketServer { _ in ["ok": true] }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
}
