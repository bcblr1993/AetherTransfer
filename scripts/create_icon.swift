import AppKit

// 1024 画布，macOS 图标网格：824 主体，圆角 185。浅色底 + 蓝色文件夹 + 上下行箭头。
let size = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func fill(_ path: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
    c.saveGState(); c.addPath(path); c.clip()
    c.drawLinearGradient(g, start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}
func fill(_ path: CGPath, _ color: CGColor) { c.addPath(path); c.setFillColor(color); c.fillPath() }
func withShadow(blur: CGFloat, dy: CGFloat, _ color: CGColor, _ draw: () -> Void) {
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: color)
    c.beginTransparencyLayer(auxiliaryInfo: nil); draw(); c.endTransparencyLayer(); c.restoreGState()
}
func arrow(from: CGPoint, to: CGPoint, color: CGColor) {
    let width: CGFloat = 40, head: CGFloat = 64, direction: CGFloat = to.y > from.y ? 1 : -1
    c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: from); c.addLine(to: CGPoint(x: to.x, y: to.y - direction * width * 0.3)); c.strokePath()
    c.move(to: CGPoint(x: to.x - head * 0.85, y: to.y - direction * head)); c.addLine(to: to)
    c.addLine(to: CGPoint(x: to.x + head * 0.85, y: to.y - direction * head)); c.strokePath()
}

// 底板
let plate = rounded(body, 185)
withShadow(blur: 28, dy: -14, CGColor(gray: 0, alpha: 0.35)) { fill(plate, rgb(0x000000)) }
fill(plate, gradient([rgb(0xFFFFFF), rgb(0xDDE4F0)]), top: 924, bottom: 100)
c.saveGState(); c.addPath(rounded(body.insetBy(dx: 2, dy: 2), 183)); c.setLineWidth(4); c.replacePathWithStrokedPath(); c.clip()
c.drawLinearGradient(gradient([white(0.9), white(0.04), white(0.36)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
c.restoreGState()

// 文件夹：后片、纸张、前片
let back = CGMutablePath()
back.addPath(rounded(CGRect(x: 196, y: 238, width: 632, height: 470), 52))
back.addPath(rounded(CGRect(x: 196, y: 600, width: 256, height: 152), 44))
let front = rounded(CGRect(x: 196, y: 238, width: 632, height: 404), 52)
withShadow(blur: 34, dy: -18, rgb(0x1E3A8A, 0.32)) {
    fill(back, gradient([rgb(0x3B82F6), rgb(0x1D4ED8)]), top: 752, bottom: 238)
    fill(rounded(CGRect(x: 236, y: 300, width: 552, height: 380), 26), gradient([white(1), rgb(0xE8EEF8)]), top: 680, bottom: 300)
    fill(front, gradient([rgb(0x7DB4FF), rgb(0x3B82F6), rgb(0x2563EB)], [0, 0.55, 1]), top: 642, bottom: 238)
}
c.saveGState(); c.addPath(front); c.clip()
fill(rounded(CGRect(x: 196, y: 630, width: 632, height: 40), 20), white(0.45))
c.restoreGState()

// 压印的上传 / 下载箭头
for (dy, color) in [(CGFloat(-5), rgb(0x2453C9)), (0, white(1))] {
    arrow(from: CGPoint(x: 440, y: 318 + dy), to: CGPoint(x: 440, y: 562 + dy), color: color)
    arrow(from: CGPoint(x: 584, y: 562 + dy), to: CGPoint(x: 584, y: 318 + dy), color: color)
}

let bitmap = NSBitmapImageRep(cgImage: c.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
