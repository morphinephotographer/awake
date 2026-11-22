import AppKit

// Usage: swift MakeIcon.swift <out.iconset>
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.09, alpha: 1)])!.draw(in: bg, angle: -90)
    bg.addClip()

    // Notch
    let nw = r.width * 0.5, nh = r.width * 0.16
    let n = NSRect(x: r.midX - nw / 2, y: r.maxY - nh, width: nw, height: nh)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: n.minX, y: n.minY, width: nw, height: nh * 2),
                 xRadius: nh * 0.55, yRadius: nh * 0.55).fill()

    // Green dot in the notch
    let d = nh * 0.42
    NSColor(red: 0.24, green: 0.88, blue: 0.48, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: n.maxX - nh * 0.55 - d, y: n.minY + (nh - d) / 2, width: d, height: d)).fill()

    // Wordmark
    var font = NSFont.systemFont(ofSize: r.width * 0.36, weight: .bold)
    if let rounded = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: rounded, size: font.pointSize) {
        font = f
    }
    let str = NSAttributedString(string: "a.", attributes: [.font: font, .foregroundColor: NSColor.white])
    let sz = str.size()
    str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 - r.height * 0.06))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in items {
    try png(px).write(to: out.appendingPathComponent("\(name).png"))
}
print("icon ok")
