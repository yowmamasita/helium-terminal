import AppKit
import GhosttyKit
import XCTest
@testable import helium_terminal

final class ClipboardTests: XCTestCase {
    func testCancellationConsumesRequestBeforeLateAllow() {
        var responses: [Bool] = []
        let confirmation = ClipboardConfirmation { responses.append($0) }
        var dismissed = 0
        confirmation.dismiss = {
            XCTAssertFalse(confirmation.isPending)
            dismissed += 1
        }

        confirmation.cancel()
        confirmation.resolve(allowed: true) // a sheet completion delivered after the pane closed
        confirmation.cancel()

        XCTAssertEqual(responses, [false], "native state must be denied exactly once, never allowed after close")
        XCTAssertEqual(dismissed, 1)
        XCTAssertFalse(confirmation.isPending)
    }

    func testResolvedRequestCannotBeConsumedReentrantly() {
        var confirmation: ClipboardConfirmation!
        var responses: [Bool] = []
        confirmation = ClipboardConfirmation { allowed in
            responses.append(allowed)
            confirmation.cancel()
            confirmation.resolve(allowed: false)
        }

        confirmation.resolve(allowed: true)
        confirmation.cancel()
        XCTAssertEqual(responses, [true], "reentrant teardown must not deny an already-consumed native pointer")
    }

    func testCancellationReleasesPayloadWhileUICompletionRemainsQueued() {
        final class Payload {}
        var payload: Payload? = Payload()
        weak var retainedPayload = payload
        let confirmation = ClipboardConfirmation { [payload] _ in
            withExtendedLifetime(payload) {}
        }
        payload = nil
        XCTAssertNotNil(retainedPayload)

        confirmation.cancel()
        XCTAssertNil(retainedPayload, "queued UI work may retain the token, but not native completion contents")
        XCTAssertFalse(confirmation.isPending)
        withExtendedLifetime(confirmation) {}
    }

    func testClosingPaneConsumesNativeClipboardRequestBeforeQueuedPresentation() throws {
        XCTAssertEqual(initializeGhosttyForTesting(), GHOSTTY_SUCCESS)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helium-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousSocket = ProcessInfo.processInfo.environment["HELIUM_SOCKET"]
        let previousState = ProcessInfo.processInfo.environment["HELIUM_STATE_FILE"]
        setenv("HELIUM_SOCKET", directory.appendingPathComponent("api.sock").path, 1)
        setenv("HELIUM_STATE_FILE", directory.appendingPathComponent("state.json").path, 1)
        defer {
            if let previousSocket { setenv("HELIUM_SOCKET", previousSocket, 1) } else { unsetenv("HELIUM_SOCKET") }
            if let previousState { setenv("HELIUM_STATE_FILE", previousState, 1) } else { unsetenv("HELIUM_STATE_FILE") }
        }
        let configFile = directory.appendingPathComponent("config")
        try Data("clipboard-read = ask\nshell-integration = none\n".utf8).write(to: configFile)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, configFile.path)
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s(
            userdata: nil, supports_selection_clipboard: false,
            wakeup_cb: { _ in }, action_cb: { _, _, _ in true },
            read_clipboard_cb: { ud, _, state, _, _, _ in
                guard let surface = SurfaceView.from(ud)?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
                // Exercise real native confirmation state without reading the owner's pasteboard.
                "text/plain".withCString { mime in
                    "synthetic clipboard".withCString { text in
                        var content = ghostty_clipboard_content_s(mime: mime, data: text, len: strlen(text))
                        withUnsafePointer(to: &content) { contents in
                            var result = ghostty_clipboard_complete_s(contents: contents, contents_len: 1,
                                available: nil, available_len: 0, confirmed: false, remember: false)
                            ghostty_surface_complete_clipboard_request(surface, &result, state)
                        }
                    }
                }
                return GHOSTTY_CLIPBOARD_READ_STARTED
            },
            confirm_read_clipboard_cb: { ud, content, state, request in
                Ghostty.confirmClipboard(ud, content, state, request)
            },
            write_clipboard_cb: { _, _, _, _, _ in XCTFail("a denied read must not write the pasteboard") },
            close_surface_cb: { _, _ in })
        let app = try XCTUnwrap(ghostty_app_new(&runtime, config))
        defer { ghostty_app_free(app) }
        let view = SurfaceView(app: app, workingDirectory: directory.path,
            command: "/usr/bin/printf '\\033]52;c;?\\007'; /bin/sleep 30")
        defer { view.destroy() }
        XCTAssertNotNil(view.surface)
        let deadline = Date() + 5
        while view.clipboardConfirmations.isEmpty, Date() < deadline {
            ghostty_app_tick(app)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let confirmation = try XCTUnwrap(view.clipboardConfirmations.first)
        XCTAssertTrue(confirmation.isPending)
        view.destroy()
        XCTAssertFalse(confirmation.isPending)
        XCTAssertTrue(view.clipboardConfirmations.isEmpty)
        XCTAssertNil(view.surface)
        // Run the real queued presentation after teardown. It must not present a dialog or touch freed state.
        let drained = expectation(description: "queued clipboard presentation canceled")
        DispatchQueue.main.async {
            XCTAssertFalse(confirmation.isPending)
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
    }
}
