// Launches an app and prints milliseconds until its first on-screen window appears.
import AppKit
import CoreGraphics

let path = CommandLine.arguments[1]
let start = DispatchTime.now()
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
task.arguments = ["-g", "-n", path]
try! task.run()
let name = (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
while true {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let found = list.contains { w in
        (w[kCGWindowLayer as String] as? Int) == 0 &&
        ((w[kCGWindowOwnerName as String] as? String).map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false) &&
        ((w[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200
    }
    if found { break }
    if DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds > 30_000_000_000 { print("timeout"); exit(1) }
    usleep(5000)
}
print((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
