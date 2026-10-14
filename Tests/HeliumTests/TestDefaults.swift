import Foundation
@testable import helium_terminal

// Keep persistence tests away from the defaults of the user running the suite.
private let isolatedDefaults: Void = {
    let name = "HeliumTests.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    HeliumDefaults.standard = defaults
}()

@inline(__always)
func loadIsolatedDefaults() {
    _ = isolatedDefaults
}
