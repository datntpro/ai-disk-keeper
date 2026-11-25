// Generates a placeholder app icon iconset. Usage: swift scripts/make-placeholder-icon.swift <out.iconset>
import AppKit

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2225, yRadius: size * 0.2225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.75, alpha: 1))
    gradient?.draw(in: path, angle: -90)

    var drawn = false
    if let symbol = NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular)
            .applying(.init(paletteColors: [.white, .white]))
        if let img = symbol.withSymbolConfiguration(config) {
            let target = size * 0.6
            let scale = min(target / img.size.width, target / img.size.height)
            let w = img.size.width * scale, h = img.size.height * scale
            img.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
            drawn = true
        }
    }
    if !drawn {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.4, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: "AI", attributes: attrs)
        let ts = text.size()
        text.draw(at: NSPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2))
    }
    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-placeholder-icon.swift <out.iconset>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            guard let data = render(pixels: base * scale) else {
                FileHandle.standardError.write(Data("error: failed to render \(base)@\(scale)x\n".utf8))
                exit(1)
            }
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            try data.write(to: outDir.appendingPathComponent(name))
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
