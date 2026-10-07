import AppKit
let image = NSImage(size: NSSize(width: 512, height: 512))
image.lockFocus()
NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.57, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 108, yRadius: 108).fill()
for (x, direction) in [(170.0, 1.0), (342.0, -1.0)] {
    let path = NSBezierPath()
    let bottom = direction > 0 ? 152.0 : 360.0
    let top = direction > 0 ? 360.0 : 152.0
    path.move(to: NSPoint(x: x, y: bottom)); path.line(to: NSPoint(x: x, y: top))
    path.move(to: NSPoint(x: x - 55, y: top - direction * 55))
    path.line(to: NSPoint(x: x, y: top)); path.line(to: NSPoint(x: x + 55, y: top - direction * 55))
    path.lineWidth = 30; path.lineCapStyle = .round; path.lineJoinStyle = .round
    NSColor.white.setStroke(); path.stroke()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
