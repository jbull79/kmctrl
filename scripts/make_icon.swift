// Renders the KMctrl app icon (keyboard + cursor) at all required sizes.
//   swift scripts/make_icon.swift            -> full set into the asset catalog
//   swift scripts/make_icon.swift preview    -> single 1024 preview to /tmp/kmctrl-icon.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = "KMctrl/Resources/Assets.xcassets/AppIcon.appiconset"
let preview = CommandLine.arguments.contains("preview")
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(_ ts: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(ts), height: Int(ts), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle background
    let inset = ts * 0.045
    let body = CGRect(x: inset, y: inset, width: ts - inset * 2, height: ts - inset * 2)
    ctx.addPath(roundedRect(body, ts * 0.2237)); ctx.clip()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [c(0.13, 0.16, 0.24), c(0.08, 0.62, 0.58)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: ts), end: CGPoint(x: ts, y: 0), options: [])
    let hl = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.18), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: ts * 0.5, y: ts * 0.85), startRadius: 0,
                           endCenter: CGPoint(x: ts * 0.5, y: ts * 0.85), endRadius: ts * 0.7, options: [])

    // Keyboard
    let kbW = ts * 0.62, kbH = ts * 0.40
    let kb = CGRect(x: (ts - kbW) / 2, y: ts * 0.20, width: kbW, height: kbH)
    ctx.setShadow(offset: .zero, blur: ts * 0.02, color: c(0, 0, 0, 0.25))
    ctx.addPath(roundedRect(kb, ts * 0.055)); ctx.setFillColor(c(1, 1, 1, 0.96)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Keys cut as coloured holes
    ctx.setFillColor(c(0.10, 0.34, 0.40, 1))
    let pad = kb.width * 0.085
    let cols = 5, rows = 3
    let keyGap = kb.width * 0.03
    let keyW = (kb.width - pad * 2 - keyGap * CGFloat(cols - 1)) / CGFloat(cols)
    let keyH = keyW
    let topY = kb.maxY - pad - keyH
    for r in 0..<rows {
        for col in 0..<cols {
            let x = kb.minX + pad + CGFloat(col) * (keyW + keyGap) + CGFloat(r) * keyW * 0.18
            let y = topY - CGFloat(r) * (keyH + keyGap)
            if x + keyW > kb.maxX - pad { continue }
            ctx.addPath(roundedRect(CGRect(x: x, y: y, width: keyW, height: keyH), keyW * 0.22))
        }
    }
    let sbY = kb.minY + pad
    ctx.addPath(roundedRect(CGRect(x: kb.minX + pad * 2.2, y: sbY, width: kb.width - pad * 4.4, height: keyH * 0.7), keyH * 0.2))
    ctx.fillPath()

    // Cursor arrow (mouse control)
    let s = ts
    let a = CGMutablePath()
    a.move(to: CGPoint(x: s * 0.60, y: s * 0.52))
    a.addLine(to: CGPoint(x: s * 0.60, y: s * 0.80))
    a.addLine(to: CGPoint(x: s * 0.665, y: s * 0.715))
    a.addLine(to: CGPoint(x: s * 0.715, y: s * 0.815))
    a.addLine(to: CGPoint(x: s * 0.755, y: s * 0.795))
    a.addLine(to: CGPoint(x: s * 0.705, y: s * 0.695))
    a.addLine(to: CGPoint(x: s * 0.80, y: s * 0.685))
    a.closeSubpath()
    ctx.setShadow(offset: .zero, blur: ts * 0.02, color: c(0, 0, 0, 0.35))
    ctx.addPath(a); ctx.setFillColor(c(1, 1, 1, 1)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(a); ctx.setStrokeColor(c(0.10, 0.34, 0.40, 1)); ctx.setLineWidth(ts * 0.012); ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

if preview {
    write(drawIcon(1024), "/tmp/kmctrl-icon.png")
    print("wrote /tmp/kmctrl-icon.png")
} else {
    let map: [(CGFloat, [String])] = [
        (16, ["icon_16x16.png"]),
        (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
        (64, ["icon_32x32@2x.png"]),
        (128, ["icon_128x128.png"]),
        (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
        (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
        (1024, ["icon_512x512@2x.png"]),
    ]
    for (sz, names) in map {
        let img = drawIcon(sz)
        for n in names { write(img, "\(outDir)/\(n)") }
    }
    print("wrote KMctrl app icon set")
}
