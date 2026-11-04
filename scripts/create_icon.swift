import AppKit

// The app and product page deliberately share one approved master image.
let source = URL(fileURLWithPath: "website_content/apps/aethertransfer/media/icon.png")
guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOf: source) else {
    fatalError("Usage: swift scripts/create_icon.swift output.png (run from repository root)")
}
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
           operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))
