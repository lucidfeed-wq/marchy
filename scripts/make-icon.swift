// Draws Marchy's app icon (tiled windows, Tokyo Night colours) -> AppIcon.iconset PNGs.
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18).fill()
    let g = s * 0.035, pad = s * 0.2
    let inner = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let half = (inner.width - g) / 2
    let tiles: [(NSRect, NSColor)] = [
        (NSRect(x: inner.minX, y: inner.minY, width: half, height: inner.height), NSColor(red: 0.48, green: 0.64, blue: 0.97, alpha: 1)),
        (NSRect(x: inner.minX + half + g, y: inner.minY + (inner.height + g) / 2, width: half, height: (inner.height - g) / 2), NSColor(red: 0.73, green: 0.60, blue: 0.97, alpha: 1)),
        (NSRect(x: inner.minX + half + g, y: inner.minY, width: half, height: (inner.height - g) / 2), NSColor(red: 0.62, green: 0.81, blue: 0.42, alpha: 1)),
    ]
    for (r, c) in tiles { c.setFill(); NSBezierPath(roundedRect: r, xRadius: s * 0.04, yRadius: s * 0.04).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
