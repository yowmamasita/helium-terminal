import AppKit

/// Gmail-style labels: named colors shared by all tabs, stored in user defaults.
struct TabLabel: Equatable {
    let name: String
    let color: String

    static let palette: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Mint", .systemMint), ("Teal", .systemTeal), ("Blue", .systemBlue), ("Indigo", .systemIndigo),
        ("Purple", .systemPurple), ("Pink", .systemPink), ("Brown", .systemBrown), ("Gray", .systemGray),
    ]

    var nsColor: NSColor { Self.palette.first { $0.name == color }?.color ?? .systemGray }

    /// Light fills need dark text to stay readable.
    var textColor: NSColor { ["Yellow", "Mint"].contains(color) ? .black : .white }
}

enum LabelStore {
    private static let key = "TabLabels"

    static var all: [TabLabel] {
        get {
            (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap { d in
                guard let n = d["name"], let c = d["color"] else { return nil }
                return TabLabel(name: n, color: c)
            }
        }
        set { UserDefaults.standard.set(newValue.map { ["name": $0.name, "color": $0.color] }, forKey: key) }
    }

    static func label(named name: String) -> TabLabel? { all.first { $0.name == name } }

    /// Adds a label, or recolors it if the name exists.
    static func save(_ label: TabLabel) {
        var labels = all.filter { $0.name != label.name }
        labels.append(label)
        all = labels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func delete(_ name: String) { all = all.filter { $0.name != name } }
}
