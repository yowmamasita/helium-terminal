import XCTest
@testable import helium_terminal

final class UpdaterTests: XCTestCase {
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
    }

    /// A notarized app from another team must be rejected; only our own team's builds install.
    func testSignatureCheckRequiresSameTeam() throws {
        let other = URL(fileURLWithPath: "/Applications/cmux.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other.path), "needs a notarized third-party app")
        let team = try XCTUnwrap(Updater.teamID(of: other))
        let id = try XCTUnwrap(Bundle(url: other)?.bundleIdentifier)
        XCTAssertTrue(Updater.verify(other, team: team, identifier: id))
        XCTAssertFalse(Updater.verify(other, team: "7RX5G7H8DW", identifier: id))
        // The same team's other apps are rejected too: only Helium's bundle ID installs.
        XCTAssertFalse(Updater.verify(other, team: team, identifier: "io.github.yowmamasita.helium-terminal"))
        // Ad-hoc builds have no team, so they never self-update.
        XCTAssertNil(Updater.teamID(of: URL(fileURLWithPath: "build/Helium Terminal.app")))
    }
}
