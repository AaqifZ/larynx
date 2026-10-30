// Draws an app icon (a white SF Symbol on a gradient squircle) and writes an .icns file.
// Usage: swift make-icon.swift <symbol> <top hex> <bottom hex> <out.icns>
import AppKit

let a = CommandLine.arguments
guard a.count == 5 else { print("usage: make-icon.swift <symbol> <top hex> <bottom hex> <out.icns>"); exit(2) }
func color(_ hex: String) -> NSColor {
    let v = UInt32(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's grid: an 824 pt body on a 1024 pt canvas, corner radius 185.4.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185.4 * s, yRadius: 185.4 * s)
    NSGradient(starting: color(a[2]), ending: color(a[3]))!.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 440 * s, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: a[1], accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let g = glyph.size
    glyph.draw(in: NSRect(x: body.midX - g.width / 2, y: body.midY - g.height / 2, width: g.width, height: g.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", a[4]]
try p.run(); p.waitUntilExit()
try FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
