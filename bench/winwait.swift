// Launches an app and prints milliseconds until its first on-screen window appears.
import AppKit
import CoreGraphics

let path = CommandLine.arguments[1]
// Optional window owner name, when it differs from the bundle's file name (iTerm.app runs as "iTerm2").
let owner = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
// Windows already on screen (e.g. the owner's own Helium) don't count as the new launch.
let existing = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .compactMap { $0[kCGWindowNumber as String] as? Int })
let start = DispatchTime.now()
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
// Pass HELIUM_* through so a benchmarked Helium uses throwaway state and socket, never the owner's.
let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("HELIUM_") }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
task.arguments = ["-g", "-n"] + env + [path, "--args", "-ApplePersistenceIgnoreState", "YES"]
try! task.run()
let name = owner ?? (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
while true {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let found = list.contains { w in
        (w[kCGWindowLayer as String] as? Int) == 0 &&
        !existing.contains(w[kCGWindowNumber as String] as? Int ?? -1) &&
        ((w[kCGWindowOwnerName as String] as? String).map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false) &&
        ((w[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200
    }
    if found { break }
    if DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds > 30_000_000_000 { print("timeout"); exit(1) }
    usleep(5000)
}
print((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
