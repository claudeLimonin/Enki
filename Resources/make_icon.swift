// Génère Resources/AppIcon.icns. Usage : swift Resources/make_icon.swift
import AppKit

let size: CGFloat = 1024

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Forme macOS : carré arrondi de 824 px centré, avec ombre portée.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Fond : dégradé nuit bleue → violet.
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.42, green: 0.20, blue: 0.85, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.16, blue: 0.48, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.07, blue: 0.20, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Halo lumineux derrière la courbe.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0.35).cgColor,
        NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])

    // Curseurs : 7 rails avec boutons dessinant une courbe en « sourire ».
    let levels: [CGFloat] = [0.78, 0.62, 0.42, 0.34, 0.46, 0.66, 0.82]
    let top: CGFloat = 770, bottom: CGFloat = 255
    let xs = levels.indices.map { 512 + CGFloat($0 - 3) * 92 }
    let knobs = zip(xs, levels).map { CGPoint(x: $0, y: bottom + (top - bottom) * $1) }

    for (x, knob) in zip(xs, knobs) {
        // Rail.
        let rail = CGPath(roundedRect: CGRect(x: x - 9, y: bottom, width: 18, height: top - bottom),
                          cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(rail)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.fillPath()
        // Partie remplie sous le bouton.
        let filled = CGPath(roundedRect: CGRect(x: x - 9, y: bottom, width: 18, height: knob.y - bottom),
                            cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.addPath(filled)
        ctx.clip()
        let fillGrad = CGGradient(colorsSpace: space, colors: [
            NSColor(srgbRed: 0.30, green: 0.55, blue: 1, alpha: 0.9).cgColor,
            NSColor(srgbRed: 0.45, green: 0.95, blue: 1, alpha: 0.9).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fillGrad, start: CGPoint(x: x, y: bottom), end: CGPoint(x: x, y: top), options: [])
        ctx.restoreGState()
    }

    // Courbe lisse passant par les boutons (Catmull-Rom).
    let curve = CGMutablePath()
    let pts = [CGPoint(x: knobs[0].x - 92, y: knobs[0].y + 30)] + knobs + [CGPoint(x: knobs.last!.x + 92, y: knobs.last!.y + 30)]
    curve.move(to: pts[1])
    for i in 1..<(pts.count - 2) {
        let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        curve.addCurve(to: p2, control1: c1, control2: c2)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: NSColor(srgbRed: 0.4, green: 0.9, blue: 1, alpha: 1).cgColor)
    ctx.addPath(curve)
    ctx.setStrokeColor(NSColor(srgbRed: 0.65, green: 0.95, blue: 1, alpha: 1).cgColor)
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Boutons.
    for k in knobs {
        let r: CGFloat = 34
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addEllipse(in: CGRect(x: k.x - r, y: k.y - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: k.x - r, y: k.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let knobGrad = CGGradient(colorsSpace: space, colors: [
            NSColor.white.cgColor,
            NSColor(srgbRed: 0.82, green: 0.86, blue: 0.95, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(knobGrad, start: CGPoint(x: k.x, y: k.y + r), end: CGPoint(x: k.x, y: k.y - r), options: [])
        ctx.restoreGState()
    }

    // Reflet subtil en haut de la tuile.
    let shine = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Liseré.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
let masterURL = iconset.appendingPathComponent("icon_512x512@2x.png")
try master.representation(using: .png, properties: [:])!.write(to: masterURL)

func resized(_ px: Int, name: String) throws {
    let img = NSImage(size: NSSize(width: px, height: px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    img.addRepresentation(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for s in [16, 32, 128, 256, 512] {
    try resized(s, name: "icon_\(s)x\(s).png")
    if s != 512 { try resized(s * 2, name: "icon_\(s)x\(s)@2x.png") }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK : Resources/AppIcon.icns" : "Échec iconutil")
