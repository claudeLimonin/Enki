// Génère Resources/AppIcon.icns à partir de Resources/AppIcon-source.png
// (image de l'icône « Enki Audio » : carré arrondi sur fond blanc).
// Usage : swift Resources/make_icon.swift
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let source = NSImage(contentsOf: dir.appendingPathComponent("AppIcon-source.png"))!
let srcRep = source.representations.first as! NSBitmapImageRep
let sw = CGFloat(srcRep.pixelsWide), sh = CGFloat(srcRep.pixelsHigh)

// Carré arrondi dans l'image source (mesuré) : on rogne légèrement à l'intérieur
// pour ne garder aucun pixel du fond blanc.
let tileCenter = CGPoint(x: 625 / 1254 * sw, y: 628.5 / 1254 * sh)
let tileSide: CGFloat = 1006 / 1254 * sw
let cornerRatio: CGFloat = 0.268

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    // Grille des icônes macOS : carré de 824 sur 1024, centré, avec ombre portée.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: tile, cornerWidth: 824 * s * cornerRatio, cornerHeight: 824 * s * cornerRatio, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.05, blue: 0.25, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Coordonnées de l'image source (origine en bas à gauche pour AppKit).
    let from = CGRect(x: tileCenter.x - tileSide / 2, y: sh - tileCenter.y - tileSide / 2, width: tileSide, height: tileSide)
    source.draw(in: tile, from: from, operation: .copy, fraction: 1)
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try render(s).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(s)x\(s).png"))
    try render(s * 2).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
try render(1024).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("AppIcon-preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK : Resources/AppIcon.icns" : "Échec iconutil")
