// Renders the DMG window background (design "Install LiteEcho") so it never goes stale.
// Usage: swift scripts/make-dmg-background.swift <out-dir>
// Writes dmg-background.png (780x400), dmg-background@2x.png (1560x800) and
// dmg-background.tiff (multi-resolution, via tiffutil -cathidpicheck; Finder uses it on Retina).
// Coordinates below are top-left origin, in points.
import AppKit

let W: CGFloat = 780, H: CGFloat = 400
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: a)
}

func render(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W * CGFloat(scale), height: H * CGFloat(scale)) // 72 dpi * scale handled below
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let cg = gc.cgContext
    // Flip to top-left origin and scale to points.
    cg.translateBy(x: 0, y: H * CGFloat(scale))
    cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    // Gradient, diagonal.
    let grad = NSGradient(colors: [hex(0x0F172A), hex(0x132038), hex(0x0E2A33)],
                          atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
    grad.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: W, y: H), options: [])

    // Waveform bars (faint teal).
    let teal = hex(0x5EEAD4, 0.18)
    // bottom-left: x 40-80, y 280-380 (centred on y 330)
    for (i, h) in [34, 70, 100, 62].enumerated() {
        let hh = CGFloat(h)
        teal.setFill()
        NSBezierPath(roundedRect: NSRect(x: 40 + CGFloat(i) * 12, y: 330 - hh / 2, width: 6, height: hh),
                     xRadius: 3, yRadius: 3).fill()
    }
    // top-right: x 700-740, y 24-106 (centred on y 65)
    for (i, h) in [48, 82, 56, 30].enumerated() {
        let hh = CGFloat(h)
        teal.setFill()
        NSBezierPath(roundedRect: NSRect(x: 700 + CGFloat(i) * 12, y: 65 - hh / 2, width: 6, height: hh),
                     xRadius: 3, yRadius: 3).fill()
    }

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let a = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        let h = a.size().height
        a.draw(in: NSRect(x: 0, y: centerY - h / 2, width: W, height: h))
    }
    text("Install LiteEcho", size: 24, weight: .semibold, color: hex(0xE6EDF7), centerY: 49)
    text("Drag the app onto the Applications folder", size: 13, weight: .regular, color: hex(0x93A3BD), centerY: 78)
    text("Runs entirely on this Mac \u{00B7} Apple Silicon \u{00B7} macOS 14 or later", size: 12,
         weight: .regular, color: hex(0x93A3BD), centerY: 370)

    // Dashed arrow.
    cg.saveGState()
    let arrowColor = hex(0x5EEAD4, 0.9)
    cg.setStrokeColor(arrowColor.cgColor)
    cg.setLineWidth(4); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.setLineDash(phase: 0, lengths: [2, 12])
    cg.move(to: CGPoint(x: 302, y: 215)); cg.addLine(to: CGPoint(x: 466, y: 215)); cg.strokePath()
    cg.setLineDash(phase: 0, lengths: [])
    cg.move(to: CGPoint(x: 474, y: 203)); cg.addLine(to: CGPoint(x: 486, y: 215))
    cg.addLine(to: CGPoint(x: 474, y: 227)); cg.strokePath()
    cg.restoreGState()

    // Mid-tone pill behind Finder's icon labels (y ~ 285-311). Finder draws labels black (light
    // appearance) or white (dark) and scripts cannot change that; this slate has ~4.5:1 contrast
    // against both.
    hex(0x75859D).setFill()
    for cx in [214.0, 564.0] {
        NSBezierPath(roundedRect: NSRect(x: cx - 70, y: 285, width: 140, height: 26), xRadius: 12, yRadius: 12).fill()
    }

    NSGraphicsContext.current = nil
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String, dpi: CGFloat) {
    // Tag the DPI so tiffutil/Finder treat the @2x image as 144 dpi.
    rep.size = NSSize(width: CGFloat(rep.pixelsWide) * 72 / dpi, height: CGFloat(rep.pixelsHigh) * 72 / dpi)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
write(render(scale: 1), "dmg-background.png", dpi: 72)
write(render(scale: 2), "dmg-background@2x.png", dpi: 144)

let t = Process()
t.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
t.arguments = ["-cathidpicheck", outDir + "/dmg-background.png", outDir + "/dmg-background@2x.png",
               "-out", outDir + "/dmg-background.tiff"]
try! t.run(); t.waitUntilExit()
exit(t.terminationStatus)
