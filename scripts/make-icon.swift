// Draws the NAS Mover app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    let s = CGFloat(size) / 1024
    g.scaleBy(x: s, y: s)

    // Squircle body on Apple's 1024 grid (824 pt body, 100 pt margin), with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    g.addPath(bodyPath)
    g.setFillColor(color(0x123A8F))
    g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(bodyPath)
    g.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x3B82F6), color(0x1E3A8A), color(0x0B1F4D)] as CFArray, locations: [0, 0.55, 1])!
    g.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Glassy highlight across the top.
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
    g.restoreGState()

    // Two NAS enclosures.
    func nas(x: CGFloat) {
        let box = CGRect(x: x, y: 290, width: 220, height: 400)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.35))
        g.addPath(CGPath(roundedRect: box, cornerWidth: 34, cornerHeight: 34, transform: nil))
        g.setFillColor(color(0xF8FAFC))
        g.fillPath()
        g.restoreGState()
        // Top edge accent.
        g.addPath(CGPath(roundedRect: CGRect(x: x, y: 650, width: 220, height: 40), cornerWidth: 34, cornerHeight: 34, transform: nil))
        g.setFillColor(color(0xE2E8F0))
        g.fillPath()
        // Drive bays with status lights.
        for i in 0..<4 {
            let y = 320 + CGFloat(i) * 78
            g.addPath(CGPath(roundedRect: CGRect(x: x + 26, y: y, width: 168, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil))
            g.setFillColor(color(0xCBD5E1))
            g.fillPath()
            g.addPath(CGPath(roundedRect: CGRect(x: x + 44, y: y + 22, width: 90, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil))
            g.setFillColor(color(0x94A3B8))
            g.fillPath()
            g.addEllipse(in: CGRect(x: x + 156, y: y + 18, width: 20, height: 20))
            g.setFillColor(color(0x10B981))
            g.fillPath()
        }
    }
    nas(x: 166)
    nas(x: 638)

    // Two-way arrows between them.
    func arrow(y: CGFloat, rightward: Bool) {
        let (a, b): (CGFloat, CGFloat) = rightward ? (414, 610) : (610, 414)
        g.setStrokeColor(color(0xFFFFFF))
        g.setLineWidth(30)
        g.setLineCap(.round)
        g.setLineJoin(.round)
        g.move(to: CGPoint(x: a, y: y))
        g.addLine(to: CGPoint(x: b, y: y))
        let d: CGFloat = rightward ? -1 : 1
        g.move(to: CGPoint(x: b + d * 48, y: y + 46))
        g.addLine(to: CGPoint(x: b, y: y))
        g.addLine(to: CGPoint(x: b + d * 48, y: y - 46))
        g.strokePath()
    }
    arrow(y: 580, rightward: true)
    arrow(y: 430, rightward: false)

    // Verified badge.
    let c = CGPoint(x: 770, y: 255)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.4))
    g.addEllipse(in: CGRect(x: c.x - 118, y: c.y - 118, width: 236, height: 236))
    g.setFillColor(color(0xFFFFFF))
    g.fillPath()
    g.restoreGState()
    g.addEllipse(in: CGRect(x: c.x - 100, y: c.y - 100, width: 200, height: 200))
    g.setFillColor(color(0x16A34A))
    g.fillPath()
    g.setStrokeColor(color(0xFFFFFF))
    g.setLineWidth(30)
    g.setLineCap(.round)
    g.setLineJoin(.round)
    g.move(to: CGPoint(x: c.x - 52, y: c.y + 2))
    g.addLine(to: CGPoint(x: c.x - 14, y: c.y - 38))
    g.addLine(to: CGPoint(x: c.x + 56, y: c.y + 44))
    g.strokePath()

    NSGraphicsContext.current = nil
    return rep
}

let root = FileManager.default.currentDirectoryPath
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root + "/Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
