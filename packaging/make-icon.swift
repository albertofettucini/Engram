import AppKit
import CoreText

// Engram app icon: a tonally-shaded, softly-glowing white "E" on a gray glass squircle.
// Same recipe as Council's orbs — highlight→mid→edge tonal fill + a soft glow halo behind it.
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
let S: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// --- squircle clip ---
let corner = S * 0.2237
cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
    cornerWidth: corner, cornerHeight: corner, transform: nil))
cg.clip()

// --- gray glass background (lighter top → darker bottom) ---
let bg = CGGradient(colorsSpace: space, colors: [c(18,20,26), c(4,5,9)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
// faint top haze for depth (like Council's dark theme)
let haze = CGGradient(colorsSpace: space, colors: [c(255,255,255,0.10), c(255,255,255,0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(haze, startCenter: CGPoint(x: S*0.5, y: S*0.80), startRadius: 0,
    endCenter: CGPoint(x: S*0.5, y: S*0.80), endRadius: S*0.62, options: [])

// --- build the "E" glyph path, centered ---
let nsFont = NSFont.systemFont(ofSize: S * 0.66, weight: .black)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "E", attributes: [.font: nsFont]))
let raw = CGMutablePath()
let ctf = nsFont as CTFont
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n)
    var pos = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
    for i in 0..<n where CTFontCreatePathForGlyph(ctf, glyphs[i], nil) != nil {
        raw.addPath(CTFontCreatePathForGlyph(ctf, glyphs[i], nil)!,
                    transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
    }
}
let bb = raw.boundingBoxOfPath
let letter = CGMutablePath()
letter.addPath(raw, transform: CGAffineTransform(
    translationX: (S - bb.width)/2 - bb.minX, y: (S - bb.height)/2 - bb.minY))
let cb = letter.boundingBoxOfPath

// --- light radiating around the E (Council's accent glow), layered wide→tight for a strong bloom ---
for (blur, alpha) in [(0.20, 0.45), (0.12, 0.62), (0.06, 0.88), (0.03, 0.98)] {
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: S*CGFloat(blur), color: c(150,186,246, CGFloat(alpha)))
    cg.addPath(letter); cg.setFillColor(c(255,255,255)); cg.fillPath()
    cg.restoreGState()
}

// --- white tonal fill (bright highlight → soft cool light at edges), clipped to the E ---
let hp = CGPoint(x: cb.minX + cb.width*0.30, y: cb.maxY - cb.height*0.22)   // highlight point
cg.saveGState()
cg.addPath(letter); cg.clip()
let tonal = CGGradient(colorsSpace: space, colors: [
    c(255,255,255), c(224,232,244), c(170,188,220),
] as CFArray, locations: [0, 0.55, 1])!
cg.drawRadialGradient(tonal, startCenter: hp, startRadius: 0,
    endCenter: hp, endRadius: max(cb.width, cb.height)*1.0, options: [.drawsAfterEndLocation])
// glossy specular hotspot
cg.setBlendMode(.plusLighter)
let shine = CGGradient(colorsSpace: space, colors: [c(255,255,255,0.55), c(255,255,255,0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(shine, startCenter: hp, startRadius: 0,
    endCenter: hp, endRadius: cb.height*0.30, options: [])
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
