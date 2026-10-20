import Foundation

/// Lossless, range-based edits to the two agent-owned configuration formats.
enum AgentConfig {
    enum ConfigError: Error { case invalidConfig }

    static func addingOpenCodePlugin(_ text: String, plugin: String) throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text
        var parser = JSONC(source)
        let root = try parser.document()
        guard case let .object(properties) = root.value else { throw ConfigError.invalidConfig }
        let target: Node
        if let entry = properties["plugin"] {
            target = entry
        } else if let tui = properties["tui"] {
            guard case let .object(nested) = tui.value else { throw ConfigError.invalidConfig }
            target = nested["plugin"] ?? root
        } else {
            target = root
        }
        let encoded = try jsonString(plugin)
        if case let .array(entries) = target.value {
            var found = false
            for entry in entries {
                switch entry.value {
                case let .string(name): found = found || name == plugin
                case let .array(tuple):
                    guard tuple.count == 2, case let .string(name) = tuple[0].value,
                          case .object = tuple[1].value else { throw ConfigError.invalidConfig }
                    found = found || name == plugin
                default: throw ConfigError.invalidConfig
                }
            }
            if found { return source }
            return replacing(source, target.range.lowerBound + 1..<target.range.lowerBound + 1,
                             with: encoded + (entries.isEmpty ? "" : ","))
        }
        guard target.range == root.range else { throw ConfigError.invalidConfig }
        // A present, non-array root plugin must never be replaced with a duplicate key.
        guard properties["plugin"] == nil else { throw ConfigError.invalidConfig }
        return replacing(source, root.range.lowerBound + 1..<root.range.lowerBound + 1,
                         with: "\"plugin\":[\(encoded)]" + (properties.isEmpty ? "" : ","))
    }

    static func addingCodexThreadTitle(_ text: String) throws -> String {
        var parser = TOML(text)
        try parser.document()
        let components: [String]
        if let title = parser.title {
            guard case let .array(values) = title.value else { throw ConfigError.invalidConfig }
            components = try values.compactMap { value in
                guard case let .string(component) = value.value else { throw ConfigError.invalidConfig }
                return ["app-name", "thread-id", "session-id"].contains(component) ? nil : component
            }
        } else {
            components = ["spinner", "project"]
        }
        let items = (try (["app-name", "thread-id"] + components).map(jsonString)).joined(separator: ", ")
        if let title = parser.title {
            // Keep comments from the replaced array, including comments between elements.
            var comments: [String] = []
            var scan = TOML(String(decoding: Array(text.utf8)[title.range], as: UTF8.self))
            scan.position = 1
            while scan.position < scan.bytes.count {
                if scan.current == 34 || scan.current == 39 { _ = try scan.string() }
                else if scan.current == 35 {
                    let start = scan.position
                    scan.comment()
                    comments.append(String(decoding: scan.bytes[start..<scan.position], as: UTF8.self))
                } else { scan.position += 1 }
            }
            let value = comments.isEmpty ? "[\(items)]" : "[\(items)\n" + comments.joined(separator: "\n") + "\n]"
            return replacing(text, title.range, with: value)
        }
        guard !parser.inlineTUI else { throw ConfigError.invalidConfig }
        let value = "[\(items)]"
        if let insertion = parser.tuiInsertion {
            return replacing(text, insertion..<insertion, with: "\nterminal_title = \(value)\n")
        }
        // A dotted global key before every table avoids duplicate [tui] declarations.
        return "tui.terminal_title = \(value)\n" + text
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func replacing(_ text: String, _ range: Range<Int>, with replacement: String) -> String {
        var bytes = Array(text.utf8)
        bytes.replaceSubrange(range, with: replacement.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Node {
        indirect enum Value {
            case object([String: Node]), array([Node]), string(String), other
        }
        let range: Range<Int>
        let value: Value
    }

    private struct JSONC {
        let bytes: [UInt8]
        var position = 0
        init(_ text: String) { bytes = Array(text.utf8) }
        mutating func space() throws {
            while position < bytes.count {
                if [9, 10, 13, 32].contains(bytes[position]) { position += 1; continue }
                guard bytes[position] == 47, position + 1 < bytes.count else { return }
                if bytes[position + 1] == 47 {
                    position += 2
                    while position < bytes.count && bytes[position] != 10 { position += 1 }
                } else if bytes[position + 1] == 42 {
                    position += 2
                    while position + 1 < bytes.count && !(bytes[position] == 42 && bytes[position + 1] == 47) { position += 1 }
                    guard position + 1 < bytes.count else { throw ConfigError.invalidConfig }
                    position += 2
                } else { return }
            }
        }
        mutating func document() throws -> Node {
            let result = try node()
            try space()
            guard position == bytes.count else { throw ConfigError.invalidConfig }
            return result
        }
        mutating func node() throws -> Node {
            try space()
            let start = position
            guard position < bytes.count else { throw ConfigError.invalidConfig }
            let first = bytes[position]
            if first == 123 || first == 91 {
                position += 1
                var properties: [String: Node] = [:]
                var entries: [Node] = []
                let close: UInt8 = first == 123 ? 125 : 93
                try space()
                while position < bytes.count && bytes[position] != close {
                    if first == 123 {
                        let key = try node()
                        guard case let .string(name) = key.value, properties[name] == nil else { throw ConfigError.invalidConfig }
                        try space()
                        guard position < bytes.count && bytes[position] == 58 else { throw ConfigError.invalidConfig }
                        position += 1
                        properties[name] = try node()
                    } else { entries.append(try node()) }
                    try space()
                    guard position < bytes.count else { throw ConfigError.invalidConfig }
                    if bytes[position] == close { break }
                    guard bytes[position] == 44 else { throw ConfigError.invalidConfig }
                    position += 1
                    try space()
                }
                guard position < bytes.count && bytes[position] == close else { throw ConfigError.invalidConfig }
                position += 1
                return Node(range: start..<position, value: first == 123 ? .object(properties) : .array(entries))
            }
            if first == 34 {
                position += 1
                while position < bytes.count {
                    if bytes[position] == 92 { position += 2; continue }
                    if bytes[position] == 34 { position += 1; break }
                    position += 1
                }
            } else {
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125, 47].contains(bytes[position]) { position += 1 }
            }
            guard position <= bytes.count, position > start else { throw ConfigError.invalidConfig }
            let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<position]), options: .fragmentsAllowed)
            return Node(range: start..<position, value: (value as? String).map(Node.Value.string) ?? .other)
        }
    }

    private struct TOML {
        let bytes: [UInt8]
        var position = 0
        var title: Node?
        var tuiInsertion: Int?
        var inlineTUI = false
        var table: [String] = []
        var keys = Set<[String]>()
        var tables = Set<[String]>()
        var dottedTables = Set<[String]>()
        init(_ text: String) { bytes = Array(text.utf8) }
        var current: UInt8? { position < bytes.count ? bytes[position] : nil }
        mutating func horizontal() { while current == 32 || current == 9 { position += 1 } }
        mutating func comment() {
            if current == 35 { while current != nil && current != 10 && current != 13 { position += 1 } }
        }
        mutating func lineEnd() throws {
            horizontal(); comment()
            guard current == nil || current == 10 || current == 13 else { throw ConfigError.invalidConfig }
            if current == 13 {
                position += 1
                guard current == 10 else { throw ConfigError.invalidConfig }
            }
            if current == 10 { position += 1 }
        }
        mutating func whitespace() {
            while true {
                horizontal(); comment()
                if current == 10 || current == 13 { position += 1 } else { return }
            }
        }
        mutating func document() throws {
            var arrayTableSerial = 0
            var arrayContext: [String] = []
            while true {
                whitespace()
                guard let first = current else {
                    let titlePath = ["tui", "terminal_title"]
                    guard !tables.contains(where: { $0.starts(with: titlePath) }),
                          !keys.contains(where: { $0.count > 2 && $0.starts(with: titlePath) }) else {
                        throw ConfigError.invalidConfig
                    }
                    return
                }
                if first == 91 {
                    position += 1
                    let isArray = current == 91
                    if isArray { position += 1 }
                    table = try key()
                    guard current == 93 else { throw ConfigError.invalidConfig }
                    position += 1
                    if isArray {
                        guard current == 93 else { throw ConfigError.invalidConfig }
                        guard !keys.contains(where: { table.starts(with: $0) }),
                              !tables.contains(table), !dottedTables.contains(table) else {
                            throw ConfigError.invalidConfig
                        }
                        position += 1
                        arrayTableSerial += 1
                        arrayContext = table
                    } else {
                        if !table.starts(with: arrayContext) { arrayContext = [] }
                        let identity = arrayContext.isEmpty ? table : ["#\(arrayTableSerial)"] + table
                        guard tables.insert(identity).inserted, !keys.contains(identity),
                              !dottedTables.contains(identity),
                              !keys.contains(where: { identity.starts(with: $0) }) else { throw ConfigError.invalidConfig }
                    }
                    try lineEnd()
                    if table == ["tui"] {
                        guard !isArray else { throw ConfigError.invalidConfig }
                        tuiInsertion = position
                    }
                } else {
                    let path = try key()
                    guard current == 61 else { throw ConfigError.invalidConfig }
                    position += 1
                    horizontal()
                    let value = try value()
                    let full = table + path
                    let identity = arrayContext.isEmpty ? full : ["#\(arrayTableSerial)"] + full
                    guard !keys.contains(where: { identity.starts(with: $0) || $0.starts(with: identity) }),
                          !tables.contains(identity) else { throw ConfigError.invalidConfig }
                    if path.count > 1 {
                        for count in 1..<path.count {
                            let prefix = table + path.prefix(count)
                            dottedTables.insert(arrayContext.isEmpty ? prefix : ["#\(arrayTableSerial)"] + prefix)
                        }
                    }
                    guard keys.insert(identity).inserted else { throw ConfigError.invalidConfig }
                    if full == ["tui"] { inlineTUI = true }
                    if full == ["tui", "terminal_title"] {
                        guard title == nil, arrayContext.isEmpty else { throw ConfigError.invalidConfig }
                        title = value
                    }
                    try lineEnd()
                }
            }
        }
        mutating func key() throws -> [String] {
            var parts: [String] = []
            while true {
                horizontal()
                if current == 34 || current == 39 {
                    let start = position
                    let part = try string(multilineAllowed: false)
                    guard position - start >= 2 else { throw ConfigError.invalidConfig }
                    parts.append(part)
                } else {
                    let start = position
                    while let c = current, (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 45 { position += 1 }
                    guard position > start else { throw ConfigError.invalidConfig }
                    parts.append(String(decoding: bytes[start..<position], as: UTF8.self))
                }
                horizontal()
                if current != 46 { return parts }
                position += 1
            }
        }
        mutating func string(multilineAllowed: Bool = true) throws -> String {
            guard let quote = current, quote == 34 || quote == 39 else { throw ConfigError.invalidConfig }
            let multiline = position + 2 < bytes.count && bytes[position + 1] == quote && bytes[position + 2] == quote
            guard multilineAllowed || !multiline else { throw ConfigError.invalidConfig }
            position += multiline ? 3 : 1
            if multiline {
                if current == 13 { position += 1; guard current == 10 else { throw ConfigError.invalidConfig } }
                if current == 10 { position += 1 }
            }
            var result: [UInt8] = []
            while let c = current {
                if c == quote {
                    if !multiline { position += 1; return String(decoding: result, as: UTF8.self) }
                    var count = 0
                    while current == quote { count += 1; position += 1 }
                    guard count <= 5 else { throw ConfigError.invalidConfig }
                    if count >= 3 {
                        result += Array(repeating: quote, count: count - 3)
                        return String(decoding: result, as: UTF8.self)
                    }
                    result += Array(repeating: quote, count: count)
                    continue
                }
                guard c >= 32 || c == 9 || (multiline && (c == 10 || c == 13)) else { throw ConfigError.invalidConfig }
                if quote == 34 && c == 92 {
                    position += 1
                    if multiline && (current == 32 || current == 9 || current == 10 || current == 13) {
                        horizontal()
                        guard current == 10 || current == 13 else { throw ConfigError.invalidConfig }
                        while current == 32 || current == 9 || current == 10 || current == 13 { position += 1 }
                        continue
                    }
                    guard let escape = current else { throw ConfigError.invalidConfig }
                    position += 1
                    let escapes: [UInt8: UInt8] = [98: 8, 116: 9, 110: 10, 102: 12, 114: 13, 34: 34, 92: 92]
                    if let decoded = escapes[escape] { result.append(decoded) }
                    else if escape == 117 || escape == 85 {
                        let count = escape == 117 ? 4 : 8
                        guard position + count <= bytes.count,
                              let number = UInt32(String(decoding: bytes[position..<position + count], as: UTF8.self), radix: 16),
                              let scalar = UnicodeScalar(number) else { throw ConfigError.invalidConfig }
                        result += String(scalar).utf8
                        position += count
                    } else { throw ConfigError.invalidConfig }
                } else { result.append(c); position += 1 }
            }
            throw ConfigError.invalidConfig
        }
        mutating func value() throws -> Node {
            let start = position
            if current == 34 || current == 39 {
                let decoded = try string()
                return Node(range: start..<position, value: .string(decoded))
            }
            if current == 91 {
                position += 1
                whitespace()
                var values: [Node] = []
                while current != 93 {
                    values.append(try value())
                    whitespace()
                    if current == 93 { break }
                    guard current == 44 else { throw ConfigError.invalidConfig }
                    position += 1
                    whitespace()
                }
                position += 1
                return Node(range: start..<position, value: .array(values))
            }
            if current == 123 {
                position += 1; horizontal()
                var fields = Set<[String]>()
                while current != 125 {
                    let path = try key()
                    guard !fields.contains(where: { path.starts(with: $0) || $0.starts(with: path) }),
                          fields.insert(path).inserted, current == 61 else { throw ConfigError.invalidConfig }
                    position += 1; horizontal()
                    _ = try value()
                    horizontal()
                    if current == 125 { break }
                    guard current == 44 else { throw ConfigError.invalidConfig }
                    position += 1; horizontal()
                    guard current != 125 else { throw ConfigError.invalidConfig }
                }
                position += 1
                return Node(range: start..<position, value: .other)
            }
            while let c = current, ![9, 10, 13, 32, 35, 44, 93, 125].contains(c) { position += 1 }
            let token = String(decoding: bytes[start..<position], as: UTF8.self)
            let patterns = [
                "^(true|false|[+-]?(inf|nan))$",
                "^[+-]?(0|[1-9](?:_?[0-9])*)(?:\\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?$",
                "^0(?:x[0-9a-fA-F](?:_?[0-9a-fA-F])*|o[0-7](?:_?[0-7])*|b[01](?:_?[01])*)$",
                "^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})?)?$",
                "^[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?$"
            ]
            guard patterns.contains(where: { token.range(of: $0, options: .regularExpression) != nil }) else { throw ConfigError.invalidConfig }
            return Node(range: start..<position, value: .other)
        }
    }
}
