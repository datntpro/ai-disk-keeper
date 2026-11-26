// Renders the Strata AppIcon.iconset. Usage: swift scripts/make-icon.swift <StrataMark.json> <out.iconset>
import AppKit

struct Layer: Decodable { let y, height, x, width, radius: Double; let color: String; let highlight: String? }
struct Shadow: Decodable { let offsetY, blur, alpha: Double }
struct Tile: Decodable { let radius: Double; let background: String; let hairline: String; let hairlineWidth: Double; let canvasFraction: Double; let shadow: Shadow }
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

    let canvas = CGFloat(pixels)
    let isSmall = pixels <= 32
    // macOS icon grid: the tile artwork is ~824/1024 of the canvas, centred, leaving room for the system shadow.
    var tileSize = canvas * mark.tile.canvasFraction
    if isSmall { tileSize = tileSize.rounded() }
    let origin = isSmall ? ((canvas - tileSize) / 2).rounded() : (canvas - tileSize) / 2
    let tileRect = NSRect(x: origin, y: origin, width: tileSize, height: tileSize)
    let tileRadius = tileSize * mark.tile.radius
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

    if !isSmall {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: mark.tile.shadow.alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -canvas * mark.tile.shadow.offsetY)
        shadow.shadowBlurRadius = canvas * mark.tile.shadow.blur
        shadow.set()
        color(mark.tile.background).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    color(mark.tile.background).setFill(); tile.fill()
    if !isSmall {
        let hair = NSBezierPath(roundedRect: tileRect.insetBy(dx: 0.5, dy: 0.5), xRadius: tileRadius, yRadius: tileRadius)
        hair.lineWidth = CGFloat(mark.tile.hairlineWidth) * max(1, canvas / 512)
        color(mark.tile.hairline).setStroke(); hair.stroke()
    }

    // Layer rects in canvas pixels, y measured from the top of the tile.
    var rects: [(NSRect, Layer)] = []
    if isSmall {
        // Snap to the pixel grid with a guaranteed >= 1 px gap between layers.
        let n = mark.small.count
        let gapFrac = n > 1 ? mark.small[1].y - (mark.small[0].y + mark.small[0].height) : 0.04
        let spanFrac = mark.small[n - 1].y + mark.small[n - 1].height - mark.small[0].y
        let gap = max(1, (gapFrac * tileSize).rounded())
        let total = max((spanFrac * tileSize).rounded(), CGFloat(n) + gap * CGFloat(n - 1))
        let h = max(1, ((total - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down))
        let used = h * CGFloat(n) + gap * CGFloat(n - 1)
        let startTop = (origin + (tileSize - used) / 2).rounded()
        for (i, l) in mark.small.enumerated() {
            let top = startTop + CGFloat(i) * (h + gap)
            let x = (origin + tileSize * l.x).rounded(), right = (origin + tileSize * (l.x + l.width)).rounded()
            rects.append((NSRect(x: x, y: canvas - top - h, width: right - x, height: h), l))
        }
    } else {
        for l in mark.layers {
            rects.append((NSRect(x: origin + tileSize * l.x, y: canvas - (origin + tileSize * (l.y + l.height)),
                                 width: tileSize * l.width, height: tileSize * l.height), l))
        }
    }
    for (rect, layer) in rects {
        let r = min(tileSize * layer.radius, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        color(layer.color).setFill(); path.fill()
        if let hl = layer.highlight, !isSmall {
            let line = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
            line.lineWidth = max(1, canvas / 512)
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
