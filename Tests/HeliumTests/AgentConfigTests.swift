import Foundation
import XCTest
@testable import helium_terminal

final class AgentConfigTests: XCTestCase {
    private let plugin = "file:///tmp/Helium%20Demo/agent%22plugin.js"

    func testConfiguredOpenCodeGetsBridgeWithoutChangingExistingLayerAcrossLaunches() throws {
        loadIsolatedDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helium-config-setup-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("config/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = directory.appendingPathComponent("tui.jsonc")
        let original = #"{"theme":"demo","plugin":["existing-plugin"]} // User notes"#
        try Data(original.utf8).write(to: existing)
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": root.appendingPathComponent("config").path]
        AgentIntegrations.install(environment: environment)
        let added = directory.appendingPathComponent("tui.json")
        let first = try Data(contentsOf: added)
        XCTAssertEqual(try String(contentsOf: existing), original)
        AgentIntegrations.install(environment: environment)
        XCTAssertEqual(try Data(contentsOf: added), first)
        XCTAssertEqual(try String(contentsOf: existing), original)
    }

    func testOpenCodePreservesJSONCSettingsAndTupleOptions() throws {
        let source = #"""
        {
          // User theme, not owned by Helium.
          "theme": "dark\"blue",
          "plugin": [
            "existing-package",
            ["configured-package", {"enabled": false, "path": "C:\\demo",}],
          ],
          "plugin_enabled": {"configured-package": false},
          "keybinds": {"leader": "ctrl+x",},
        }
        """#
        let result = try AgentConfig.addingOpenCodePlugin(source, plugin: plugin)
        var expected = try object(source)
        var plugins = try XCTUnwrap(expected["plugin"] as? [Any])
        plugins.insert(plugin, at: 0)
        expected["plugin"] = plugins
        XCTAssertTrue(NSDictionary(dictionary: try object(result)).isEqual(to: expected))
        XCTAssertTrue(result.contains("// User theme, not owned by Helium."))
        XCTAssertEqual(try AgentConfig.addingOpenCodePlugin(result, plugin: plugin), result)
    }

    func testOpenCodeUsesNestedPluginsWithoutAddingRootOverride() throws {
        let source = #"""
        {"tui": {"plugin": [["configured", {"value": "\u2603"}]], "theme": "dark"}, "model": "demo"}
        """#
        let result = try object(AgentConfig.addingOpenCodePlugin(source, plugin: plugin))
        XCTAssertNil(result["plugin"])
        let tui = try XCTUnwrap(result["tui"] as? [String: Any])
        let entries = try XCTUnwrap(tui["plugin"] as? [Any])
        XCTAssertEqual(entries.first as? String, plugin)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(tui["theme"] as? String, "dark")
        XCTAssertEqual(result["model"] as? String, "demo")
    }

    func testOpenCodeRootPluginTakesPrecedenceAndExistingTupleIsNotDuplicated() throws {
        let encoded = String(decoding: try JSONEncoder().encode(plugin), as: UTF8.self)
        let source = "{\"plugin\":[[\(encoded), {\"quiet\":true}]],\"tui\":{\"plugin\":[\"nested\"]}}"
        let result = try object(AgentConfig.addingOpenCodePlugin(source, plugin: plugin))
        let entries = try XCTUnwrap(result["plugin"] as? [Any])
        XCTAssertEqual(entries.count, 1)
        let tuple = try XCTUnwrap(entries[0] as? [Any])
        XCTAssertEqual(tuple[0] as? String, plugin)
        XCTAssertEqual((tuple[1] as? [String: Bool])?["quiet"], true)
        XCTAssertEqual((result["tui"] as? [String: [String]])?["plugin"], ["nested"])
    }

    func testOpenCodeCreatesRootPluginWhenNeitherLocationHasOne() throws {
        for source in ["", "  \n", "{ /* retained */ }", #"{"tui":{"theme":"dark"},"plugin_enabled":false}"#] {
            let output = try AgentConfig.addingOpenCodePlugin(source, plugin: plugin)
            XCTAssertEqual(try object(output)["plugin"] as? [String], [plugin])
            XCTAssertEqual(try AgentConfig.addingOpenCodePlugin(output, plugin: plugin), output)
        }
    }

    func testOpenCodeRejectsInvalidOrUnrecognizedPluginStructures() {
        for source in ["[1]", "{", "{ /* unterminated", #"{"plugin":false}"#,
                       #"{"plugin":[["name"]]}"#, #"{"plugin":[["name",true]]}"#,
                       #"{"plugin":[42]}"#, #"{"plugin":[],"plugin":[]}"#,
                       #"{"tui":{"plugin":"wrong"}}"#, #"{"tui":null}"#,
                       #"{"plugin":[],"other":"bad\q"}"#, #"{"other":oops}"#] {
            XCTAssertThrowsError(try AgentConfig.addingOpenCodePlugin(source, plugin: plugin), source)
        }
    }

    func testCodexDefaultDoesNotAlterUnrelatedTablesOrProfiles() throws {
        let source = #"""
        # User config
        model = "gpt-demo"
        [profiles.work.tui]
        terminal_title = ["profile"]
        [features]
        shell_tool = true
        [tui]
        notifications = false
        """#
        let output = try AgentConfig.addingCodexThreadTitle(source)
        XCTAssertEqual(try title(output), ["app-name", "thread-id", "spinner", "project"])
        XCTAssertEqual(try scalar(output, table: "", key: "model") as? String, "gpt-demo")
        XCTAssertEqual(try scalar(output, table: "features", key: "shell_tool") as? Bool, true)
        XCTAssertEqual(try scalar(output, table: "tui", key: "notifications") as? Bool, false)
        XCTAssertEqual(try scalar(output, table: "profiles.work.tui", key: "terminal_title") as? [String], ["profile"])
        XCTAssertTrue(output.contains("# User config"))
        XCTAssertEqual(try AgentConfig.addingCodexThreadTitle(output), output)
    }

    func testCodexQuotedDottedKeyAndEscapedComponents() throws {
        let source = #"""
        "tui" . 'terminal_title' = ['session-id', "project", "app-name", "thread-id", "agent\"name", "\u2603"] # user title
        [profiles.other]
        terminal_title = ["leave-alone"]
        """#
        let output = try AgentConfig.addingCodexThreadTitle(source)
        XCTAssertEqual(try title(output), ["app-name", "thread-id", "project", "agent\"name", "☃"])
        XCTAssertTrue(output.contains("# user title"))
        XCTAssertEqual(try scalar(output, table: "profiles.other", key: "terminal_title") as? [String], ["leave-alone"])
        XCTAssertEqual(try AgentConfig.addingCodexThreadTitle(output), output)
    }

    func testCodexMultilineArrayAndQuotedTablePreserveCommentsAndComponents() throws {
        let source = #"""
        [ 'tui' ] # display options
        "terminal_title" = [
          "session-id", # old identity
          'project',
          "model", # keep model
          "thread-id",
          "app-name",
          "app-name",
        ] # trailing explanation
        notifications = true
        """#
        let output = try AgentConfig.addingCodexThreadTitle(source)
        XCTAssertEqual(try title(output), ["app-name", "thread-id", "project", "model"])
        for comment in ["# display options", "# old identity", "# keep model", "# trailing explanation"] {
            XCTAssertTrue(output.contains(comment), comment)
        }
        XCTAssertEqual(try AgentConfig.addingCodexThreadTitle(output), output)
    }

    func testCodexAddsGlobalKeyWithoutChangingProfileTitle() throws {
        let source = #"""
        [profiles.work.tui]
        terminal_title = ["project"]
        [other]
        terminal_title = ["model"]
        """#
        let output = try AgentConfig.addingCodexThreadTitle(source)
        XCTAssertEqual(try title(output), ["app-name", "thread-id", "spinner", "project"])
        XCTAssertEqual(try scalar(output, table: "profiles.work.tui", key: "terminal_title") as? [String], ["project"])
        XCTAssertEqual(try scalar(output, table: "other", key: "terminal_title") as? [String], ["model"])
        XCTAssertEqual(try AgentConfig.addingCodexThreadTitle(output), output)
        XCTAssertEqual(try title(AgentConfig.addingCodexThreadTitle("")), ["app-name", "thread-id", "spinner", "project"])
    }

    func testCodexHandlesLiteralAndBasicMultilineStrings() throws {
        let source = "[tui]\nterminal_title = [\"\"\"project\"\"\", '''model''', \"app-\\u006eame\"]\n"
        let output = try AgentConfig.addingCodexThreadTitle(source)
        XCTAssertEqual(try title(output), ["app-name", "thread-id", "project", "model"])
        XCTAssertEqual(try AgentConfig.addingCodexThreadTitle(output), output)
    }

    func testCodexRejectsInvalidAndAmbiguousStructures() {
        for source in ["[tui", "tui.terminal_title = [\"project\"", "tui.terminal_title = true",
                       "tui.terminal_title = [1]", "tui.terminal_title = [\"bad\\q\"]",
                       "[tui]\nterminal_title = []\nterminal_title = []", "[tui]\n[tui]",
                       "tui = {terminal_title = []}", "tui = false", "x = [1 2]", "x = nope",
                       "tui.terminal_title = []\n[tui]\nnotifications = true",
                       "x = 1\nx.y = 2", "x.y = 2\nx = 1",
                       "tui.terminal_title.child = true", "[tui.terminal_title]",
                       "x = 1\n[[x]]", "x = {a = 1, a.b = 2}"] {
            XCTAssertThrowsError(try AgentConfig.addingCodexThreadTitle(source), source)
        }
    }

    private func object(_ text: String) throws -> [String: Any] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let value = try decoder.decode(JSONValue.self, from: Data(text.utf8))
        return try XCTUnwrap(value.foundation as? [String: Any])
    }

    /// The transform emits a JSON-compatible title array. Ignore only TOML comments outside strings.
    private func title(_ text: String) throws -> [String] {
        let start = try XCTUnwrap(text.range(of: "[\"app-name\""))
        var output = ""
        var quoted = false
        var escaped = false
        var comment = false
        for character in text[start.lowerBound...] {
            if comment {
                if character == "\n" { comment = false; output.append(character) }
                continue
            }
            if !quoted && character == "#" { comment = true; continue }
            output.append(character)
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "]" { break }
        }
        return try JSONDecoder().decode([String].self, from: Data(output.utf8))
    }

    /// Independently inspect unrelated simple values in the TOML fixtures.
    private func scalar(_ text: String, table: String, key: String) throws -> Any? {
        var section = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if section == table, let separator = line.firstIndex(of: "="),
                      line[..<separator].trimmingCharacters(in: .whitespaces) == key {
                return try JSONSerialization.jsonObject(with: Data(line[line.index(after: separator)...].utf8), options: .fragmentsAllowed)
            }
        }
        return nil
    }

    private enum JSONValue: Decodable {
        case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
            else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
            else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
            else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
            else { self = .object(try value.decode([String: JSONValue].self)) }
        }
        var foundation: Any {
            switch self {
            case let .object(value): return value.mapValues(\.foundation)
            case let .array(value): return value.map(\.foundation)
            case let .string(value): return value
            case let .number(value): return value
            case let .bool(value): return value
            case .null: return NSNull()
            }
        }
    }
}
