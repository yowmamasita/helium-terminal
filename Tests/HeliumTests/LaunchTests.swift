import Foundation
import XCTest
@testable import helium_terminal

final class LaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helium-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fake.app/Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: binary)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var app: URL { root.appendingPathComponent("Fake.app") }
    private var binary: URL { app.appendingPathComponent("Contents/MacOS/helium-terminal") }
    private var symlink: URL { root.appendingPathComponent("bin/helium") }

    func testAppBundleFollowsSymlinks() {
        XCTAssertEqual(Launch.appBundle(containing: binary)?.resolvingSymlinksInPath().path,
                       app.resolvingSymlinksInPath().path)
        XCTAssertEqual(Launch.appBundle(containing: symlink)?.resolvingSymlinksInPath().path,
                       app.resolvingSymlinksInPath().path)
        XCTAssertNil(Launch.appBundle(containing: root.appendingPathComponent("bin/loose")))
    }

    func testRelaunchOnlyThroughSymlink() {
        // Foundation's Bundle.main for the symlink is the symlink's directory.
        XCTAssertTrue(Launch.needsRelaunch(executable: symlink, mainBundle: root.appendingPathComponent("bin")))
        // Launched normally, Bundle.main is the app, whichever spelling of the path Foundation uses.
        XCTAssertFalse(Launch.needsRelaunch(executable: binary, mainBundle: app))
        XCTAssertFalse(Launch.needsRelaunch(executable: binary, mainBundle: app.resolvingSymlinksInPath()))
        XCTAssertFalse(Launch.needsRelaunch(executable: symlink, mainBundle: app))
        // A bare binary outside any bundle (swift run) is never relaunched.
        XCTAssertFalse(Launch.needsRelaunch(executable: root.appendingPathComponent("bin/loose"),
                                            mainBundle: root.appendingPathComponent("bin")))
    }
}
