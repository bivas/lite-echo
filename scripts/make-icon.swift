// Renders the LiteEcho app icon ("Wave face", option B) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>   (then: iconutil -c icns <out.iconset>)
//
// Artwork is in the design's 100-unit space (y down). Small sizes use simpler variants
// so the face stays legible: 3 bars at <=32 px, 5 bars at <=64 px, the full face above.
import AppKit

let navy = CGColor(red: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255, alpha: 1)
let teal = CGColor(red: 0x5E / 255, green: 0xEA / 255, blue: 0xD4 / 255, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)

struct Bar { let x, y, w, h: CGFloat }

func draw(_ ctx: CGContext, px: Int) {
    let s = CGFloat(px)
    // macOS icon grid: the tile is 824/1024 of the canvas, centred.
    let tile = s * 824 / 1024
    let origin = (s - tile) / 2
    let unit = tile / 96   // design tile spans 2...98
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin + (x - 2) * unit, y: origin + (y - 2) * unit, width: w * unit, height: h * unit)
    }
    func pill(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius * unit, cornerHeight: radius * unit, transform: nil))
        ctx.fillPath()
    }
    func dot(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: r(cx - radius, cy - radius, radius * 2, radius * 2))
    }

    // Tile with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 10 / 1024), blur: s * 20 / 1024,
                  color: CGColor(gray: 0, alpha: 0.3))
    pill(r(2, 2, 96, 96), 22, navy)
    ctx.restoreGState()

    if px <= 32 {
        for b in [Bar(x: 24, y: 34, w: 10, h: 32), Bar(x: 45, y: 18, w: 10, h: 64), Bar(x: 66, y: 34, w: 10, h: 32)] {
            pill(r(b.x, b.y, b.w, b.h), b.w / 2, teal)
        }
    } else if px <= 64 {
        for b in [Bar(x: 25, y: 36, w: 6, h: 28), Bar(x: 35, y: 28, w: 6, h: 44), Bar(x: 47, y: 18, w: 6, h: 58),
                  Bar(x: 59, y: 28, w: 6, h: 44), Bar(x: 69, y: 36, w: 6, h: 28)] {
            pill(r(b.x, b.y, b.w, b.h), 3, teal)
        }
        dot(38, 46, 3, white)
        dot(62, 46, 3, white)
    } else {
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(17, 44, 12), (25, 36, 28), (33, 28, 44), (41, 31, 38), (49, 18, 58),
                                                   (57, 31, 38), (65, 28, 44), (73, 36, 28), (81, 44, 12)]
        for (x, y, h) in bars { pill(r(x, y, 5, h), 2.5, teal) }
        dot(51.5, 15, 3.4, teal)
        pill(r(30, 42, 11, 8), 4, navy)
        pill(r(62, 42, 11, 8), 4, navy)
        dot(35.5, 46, 2.6, white)
        dot(67.5, 46, 2.6, white)
    }
}

func png(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)   // y down, like the SVG
    ctx.setShouldAntialias(true)
    draw(ctx, px: px)
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(px: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(px: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out.path)")
