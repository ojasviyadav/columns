// Draws the Columns icon candidates at 1024 px. Usage: swift icon.swift <A|B|C> <out.png>
import AppKit

let variant = CommandLine.arguments[1], out = CommandLine.arguments[2]
// "small" draws the 16 and 32 px art: fewer, thicker lines and no dots, so the columns still read.
let small = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "small"
let N: CGFloat = 1024
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
// Flipped: y grows downward, like the drawings were planned.
cg.translateBy(x: 0, y: N); cg.scaleBy(x: 1, y: -1)

// The macOS icon body: 824 pt square on the 1024 canvas, continuous corners, soft shadow below.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
func fillBody(_ top: NSColor, _ bottom: NSColor) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    cg.addPath(shape); cg.setFillColor(bottom.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(shape); cg.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    cg.restoreGState()
}
func bar(_ r: CGRect, _ c: NSColor, radius: CGFloat? = nil) {
    let rad = radius ?? min(r.width, r.height) / 2
    cg.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)); cg.setFillColor(c.cgColor); cg.fillPath()
}
func dot(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ c: NSColor) { cg.setFillColor(c.cgColor); cg.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)) }
func edge(_ a: CGFloat = 0.5) {  // a hairline of light along the top edge, as on system icons
    cg.saveGState(); cg.addPath(shape); cg.clip()
    cg.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(a).cgColor); cg.setLineWidth(3); cg.strokePath()
    cg.restoreGState()
}

// Three columns of text lines. `lines` gives each line's width as a share of the column; 0 is a paragraph gap.
let colW: CGFloat = 186, gap: CGFloat = 58
let left = (N - (3 * colW + 2 * gap)) / 2, top: CGFloat = 262, bottom: CGFloat = 762
func columnX(_ i: Int) -> CGFloat { left + CGFloat(i) * (colW + gap) }
func textColumns(ink: NSColor, heading: NSColor, lineH: CGFloat = 24, pitch: CGFloat = 50) {
    if small {  // three solid columns, the last ending early: the lines would blur into a grid at this size
        for i in 0..<3 { bar(CGRect(x: columnX(i) - 10, y: top - 22, width: colW + 20, height: (bottom - top + 44) * (i == 2 ? 0.6 : 1)), heading.withAlphaComponent(0.86), radius: 30) }
        return
    }
    let cols: [[CGFloat]] = [
        [-1, 0.001, 1, 1, 0.92, 1, 0.62, 0.001, 1, 0.96, 1],
        [1, 0.8, 0.001, 1, 1, 0.94, 1, 0.5, 0.001, 1, 1],
        [0.96, 1, 0.7, 0.001, 1, 1, 0.88, 0.44],
    ]
    for (i, lines) in cols.enumerated() {
        var y = top
        for w in lines {
            if w < 0 { bar(CGRect(x: columnX(i), y: y - 4, width: colW * 0.78, height: 40), heading, radius: 12); y += pitch + 6; continue }
            if w < 0.01 { y += pitch * 0.34; continue }
            if y + lineH > bottom + 2 { break }
            bar(CGRect(x: columnX(i), y: y, width: colW * w, height: lineH), ink, radius: 9); y += pitch
        }
    }
}
// The ribbon: a tinted band under the end of one column, up the gutter, over the start of the next, with dots.
func ribbons(_ c: NSColor, band: CGFloat, dots: CGFloat) {
    for i in 0..<2 {
        let gx = columnX(i) + colW + gap / 2
        if !small { bar(CGRect(x: gx - 15, y: top - 34, width: 30, height: bottom - top + 76), c.withAlphaComponent(band), radius: 15) }
        var y = small ? bottom + 100 : top - 14
        while y <= bottom + 22 { dot(gx, y, 11, c.withAlphaComponent(dots)); y += 37 }
    }
}

switch variant {
case "A":  // Paper: the Sepia page, ink lines, a ribbon in the page's link colour
    fillBody(rgb(0xfbf5e6), rgb(0xecdfc0))
    ribbons(rgb(0x8f4f12), band: 0.10, dots: 0.55)
    textColumns(ink: rgb(0x3b2f22, 0.80), heading: rgb(0x3b2f22))
    edge(0.7)
case "B":  // Night: the Dark page, light lines, blue ribbons
    fillBody(rgb(0x2e2e33), rgb(0x161618))
    ribbons(rgb(0x5aa9ff), band: 0.16, dots: 0.9)
    textColumns(ink: rgb(0xe4e4e6, 0.86), heading: rgb(0xffffff))
    edge(0.14)
default:  // Bars: three solid columns on blue, the last one ending early as text does
    fillBody(rgb(0x4d9bff), rgb(0x0b4fc9))
    let w: CGFloat = 170, g: CGFloat = 62, l = (N - (3 * w + 2 * g)) / 2, t: CGFloat = 250, h: CGFloat = 524
    for i in 0..<3 {
        let r = CGRect(x: l + CGFloat(i) * (w + g), y: t, width: w, height: i == 2 ? h * 0.62 : h)
        cg.saveGState(); cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x042a70, 0.35).cgColor)
        bar(r, rgb(0xffffff, 0.97), radius: 34); cg.restoreGState()
    }
    for i in 0..<2 where !small { let gx = l + CGFloat(i) * (w + g) + w + g / 2; var y = t + 14
        while y <= t + h - 10 { dot(gx, y, 12, rgb(0xffffff, 0.55)); y += 42 } }
    edge(0.35)
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
