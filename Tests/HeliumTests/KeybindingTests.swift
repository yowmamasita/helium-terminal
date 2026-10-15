import GhosttyKit
import XCTest
@testable import helium_terminal

final class KeybindingTests: XCTestCase {
    func testNumberedTabShortcuts() throws {
        XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), GHOSTTY_SUCCESS)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, Ghostty.defaultConfigPath)
        ghostty_config_finalize(config)
        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
        for (action, codepoint) in [("goto_tab:9", UInt32(57)), ("goto_tab:10", UInt32(48))] {
            let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
            XCTAssertEqual(trigger.tag, GHOSTTY_TRIGGER_UNICODE, action)
            XCTAssertEqual(trigger.key.unicode, codepoint, action)
            XCTAssertEqual(trigger.mods, GHOSTTY_MODS_SUPER, action)
        }
    }
}
