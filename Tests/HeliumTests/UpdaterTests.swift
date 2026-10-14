import Foundation
import XCTest
@testable import helium_terminal

final class UpdaterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        loadIsolatedDefaults()
    }

    func testVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.0.9", than: "0.1.0"))
    }

    func testParseRelease() throws {
        let json = """
        {"tag_name":"v0.2.0","assets":[
          {"name":"helium-terminal-0.2.0.arm64_ventura.bottle.tar.gz","browser_download_url":"https://x/bottle"},
          {"name":"helium-terminal-0.2.0-macos-arm64.zip","browser_download_url":"https://x/app.zip"}]}
        """.data(using: .utf8)
        let r = try XCTUnwrap(Updater.parseRelease(json))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.zip.absoluteString, "https://x/app.zip")
        XCTAssertNil(Updater.parseRelease(#"{"tag_name":"v0.2.0","assets":[]}"#.data(using: .utf8)))
        let insecure = #"{"tag_name":"v0.2.0","assets":[{"name":"helium-terminal-0.2.0-macos-arm64.zip","browser_download_url":"http://x/app.zip"}]}"#.data(using: .utf8)
        XCTAssertNil(Updater.parseRelease(insecure))
    }

    func testSignatureCheckRejectsMissingOrUnsignedApps() {
        let missing = URL(fileURLWithPath: "/tmp/helium-no-such-app.app")
        XCTAssertNil(Updater.teamID(of: missing))
        XCTAssertFalse(Updater.verify(missing, team: "7RX5G7H8DW"))
    }

    func testHTTPStatusMustSucceedForMetadataAndDownload() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1/status"))
        for status in [100, 199, 300, 404, 500] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            XCTAssertNotNil(Updater.httpError(response: response, error: nil), "metadata status \(status) must fail")
            XCTAssertNotNil(Updater.httpError(response: response, error: nil), "download status \(status) must fail")
        }
        for status in [200, 201, 204, 299] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            XCTAssertNil(Updater.httpError(response: response, error: nil), "status \(status) is successful")
        }
        XCTAssertNotNil(Updater.httpError(response: nil, error: nil))
        XCTAssertNotNil(Updater.httpError(response: HTTPURLResponse(url: url, statusCode: 200,
                                                                      httpVersion: "HTTP/1.1", headerFields: nil),
                                           error: URLError(.timedOut)))
    }

    func testSignedFixtureMatchesTeamAndBundleIDWhenAvailable() throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/helium-terminal-0.1.7-macos-arm64.zip")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("local notarized fixture is unavailable")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helium-updater-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", fixture.path, directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw XCTSkip("local fixture could not be unpacked") }
        let app = directory.appendingPathComponent("Helium Terminal.app")
        guard let team = Updater.teamID(of: app) else {
            throw XCTSkip("local fixture is not Developer ID signed")
        }
        XCTAssertTrue(Updater.verify(app, team: team, identifier: "io.github.yowmamasita.helium-terminal"))
        XCTAssertFalse(Updater.verify(app, team: "AAAAAAAAAA", identifier: "io.github.yowmamasita.helium-terminal"))
        XCTAssertFalse(Updater.verify(app, team: team, identifier: "com.example.not-helium"))
    }
}
