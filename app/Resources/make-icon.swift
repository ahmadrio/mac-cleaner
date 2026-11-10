// Draws the Mac Cleaner app icon (1024 × 1024 PNG) with AppKit, in the colours of screenshots/banner.png:
// a dark navy rounded square with a green free-space gauge around a sparkle.
//
// Regenerate AppIcon.icns from the repo root (intermediates stay in build/, which git ignores):
//
//   swift app/Resources/make-icon.swift build/icon.png
//   mkdir -p build/AppIcon.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s * 2)) $((s * 2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns build/AppIcon.iconset -o app/Resources/AppIcon.icns
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A four-pointed sparkle with concave sides; `radius` is the length of one point.
func sparkle(_ center: NSPoint, _ radius: CGFloat, pinch: CGFloat = 0.18) -> NSBezierPath {
    let k = radius * pinch
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    for (end, control) in [((radius, 0.0), (k, k)), ((0.0, -radius), (k, -k)),
                           ((-radius, 0.0), (-k, -k)), ((0.0, radius), (-k, k))] {
        let c = NSPoint(x: center.x + control.0, y: center.y + control.1)
        path.curve(to: NSPoint(x: center.x + end.0, y: center.y + end.1), controlPoint1: c, controlPoint2: c)
    }
    path.close()
    return path
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The body: Apple's icon grid puts an 824 pt rounded square in the middle of the 1024 pt canvas.
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.shadowColor = color(0x000000, 0.35)
shadow.set()
color(0x111821).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(starting: color(0x1F2C3D), ending: color(0x0D1218))!.draw(in: body, angle: -90)
// The banner's soft light in the top-left corner.
NSGradient(colors: [color(0x2A3E57, 0.55), color(0x2A3E57, 0)])!
    .draw(fromCenter: NSPoint(x: 300, y: 760), radius: 0, toCenter: NSPoint(x: 300, y: 760), radius: 520, options: [])
// A green glow behind the sparkle.
NSGradient(colors: [color(0x4ADE80, 0.22), color(0x4ADE80, 0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0, toCenter: NSPoint(x: 512, y: 512), radius: 300, options: [])
NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, 0.08).setStroke()
body.lineWidth = 3
body.stroke()

let center = NSPoint(x: 512, y: 512)
let green = NSGradient(starting: color(0x9AF5BE), ending: color(0x22C55E))!

// The gauge: a dim track and a green arc of free space with round ends, filled with the same gradient.
let ring: CGFloat = 272, ringWidth: CGFloat = 64
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: ring, startAngle: 0, endAngle: 360)
track.lineWidth = ringWidth
color(0xFFFFFF, 0.07).setStroke()
track.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: ring, startAngle: 90, endAngle: -160, clockwise: true)
let arcOutline = arc.cgPath.copy(strokingWithWidth: ringWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
green.draw(in: NSBezierPath(cgPath: arcOutline), angle: -90)

green.draw(in: sparkle(center, 170), angle: -90)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
