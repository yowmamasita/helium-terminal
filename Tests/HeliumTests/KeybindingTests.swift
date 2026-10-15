import GhosttyKit
import XCTest
@testable import helium_terminal

final class KeybindingTests: XCTestCase {
    func testCommandNineSelectsNinthTab() throws {
        XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), GHOSTTY_SUCCESS)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, Ghostty.defaultConfigPath)
        ghostty_config_finalize(config)
        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
        let action = "goto_tab:9"
        let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
        XCTAssertEqual(trigger.tag, GHOSTTY_TRIGGER_UNICODE)
        XCTAssertEqual(trigger.key.unicode, 57)
        XCTAssertEqual(trigger.mods, GHOSTTY_MODS_SUPER)
    }
}
