// Renders the Strata AppIcon.iconset. Usage: swift scripts/make-icon.swift <StrataMark.json> <out.iconset>
import AppKit

struct Layer: Decodable { let y, height, x, width, radius: Double; let color: String; let highlight: String? }
struct Tile: Decodable { let radius: Double; let background: String; let hairline: String; let hairlineWidth: Double }
struct Mark: Decodable { let tile: Tile; let layers: [Layer]; let small: [Layer] }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(msg)\n".utf8)); exit(1)
}

func color(_ hex: String) -> NSColor {
    var s = hex; if s.hasPrefix("#") { s.removeFirst() }
    guard let v = UInt64(s, radix: 16), s.count == 6 || s.count == 8 else { fail("bad colour \(hex)") }
    let hasA = s.count == 8
    let r = Double((v >> (hasA ? 24 : 16)) & 255) / 255, g = Double((v >> (hasA ? 16 : 8)) & 255) / 255
    let b = Double((v >> (hasA ? 8 : 0)) & 255) / 255, a = hasA ? Double(v & 255) / 255 : 1
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(_ mark: Mark, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let isSmall = pixels <= 32
    let tileRect = NSRect(x: 0, y: 0, width: size, height: size)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: size * mark.tile.radius, yRadius: size * mark.tile.radius)
    color(mark.tile.background).setFill(); tile.fill()
    if !isSmall {
        let inner = tileRect.insetBy(dx: 0.5, dy: 0.5)
        let hair = NSBezierPath(roundedRect: inner, xRadius: size * mark.tile.radius, yRadius: size * mark.tile.radius)
        hair.lineWidth = CGFloat(mark.tile.hairlineWidth) * max(1, size / 512)
        color(mark.tile.hairline).setStroke(); hair.stroke()
    }

    for layer in isSmall ? mark.small : mark.layers {
        var x = size * layer.x, w = size * layer.width, h = size * layer.height
        var top = size * layer.y
        if isSmall { top = top.rounded(); h = h.rounded(); x = x.rounded(); w = w.rounded() }
        let rect = NSRect(x: x, y: size - top - h, width: w, height: h) // flip: JSON y grows down
        let r = size * layer.radius
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        color(layer.color).setFill(); path.fill()
        if let hl = layer.highlight, !isSmall {
            let line = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
            line.lineWidth = max(1, size / 512)
            color(hl).setStroke(); line.stroke()
        }
    }
    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 3 else { fail("usage: make-icon.swift <StrataMark.json> <out.iconset>") }
guard let json = FileManager.default.contents(atPath: CommandLine.arguments[1]) else { fail("cannot read \(CommandLine.arguments[1])") }
let mark: Mark
do { mark = try JSONDecoder().decode(Mark.self, from: json) } catch { fail("invalid JSON: \(error)") }
guard mark.layers.count == 4, !mark.small.isEmpty else { fail("expected 4 layers and a small variant") }

let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    guard let data = render(mark, pixels: px) else { fail("render failed for \(name)") }
    try data.write(to: outDir.appendingPathComponent(name))
}
