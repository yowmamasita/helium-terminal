// Renders packaging/Helium.icns: a periodic-table tile for helium.
// Run: swift scripts/make-icon.swift (needs iconutil, part of Xcode tools).
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824pt rounded square centred in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.11, green: 0.12, blue: 0.17, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: path, angle: -90)
    NSColor(red: 0.35, green: 0.75, blue: 1, alpha: 0.9).setStroke()
    let ring = NSBezierPath(roundedRect: tile.insetBy(dx: 26 * s, dy: 26 * s), xRadius: 160 * s, yRadius: 160 * s)
    ring.lineWidth = 14 * s
    ring.stroke()

    func text(_ str: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint, center: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * s, weight: weight), .foregroundColor: color]
        let a = NSAttributedString(string: str, attributes: attrs)
        let w = a.size().width
        a.draw(at: NSPoint(x: center ? p.x * s - w / 2 : p.x * s, y: p.y * s))
    }
    text("2", size: 120, weight: .semibold, color: NSColor(white: 1, alpha: 0.7), at: NSPoint(x: 190, y: 700))
    text("He", size: 400, weight: .bold, color: NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1), at: NSPoint(x: 512, y: 300), center: true)
    text(">_", size: 110, weight: .medium, color: NSColor(white: 1, alpha: 0.55), at: NSPoint(x: 512, y: 165), center: true)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Helium.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "packaging/Helium.icns"]
try! p.run()
p.waitUntilExit()
exit(p.terminationStatus)
