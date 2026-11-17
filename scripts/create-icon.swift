import AppKit
import Foundation

// Render the same vector mark used in src/app-icon.tsx into a macOS iconset.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let side = points * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let factor = CGFloat(side) / 40
    let transform = NSAffineTransform()
    transform.scale(by: factor)
    transform.concat()
    NSColor(red: 54.0 / 255, green: 101.0 / 255, blue: 228.0 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 36, height: 36), xRadius: 10, yRadius: 10)
      .fill()
    NSColor.white.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 2.8
    path.lineCapStyle = .round
    for (x, low, high) in [
      (12.0, 16.0, 24.0), (17.0, 11.0, 29.0), (23.0, 14.0, 26.0), (28.0, 18.0, 22.0),
    ] {
      path.move(to: NSPoint(x: x, y: low))
      path.line(to: NSPoint(x: x, y: high))
    }
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: destination.appendingPathComponent(name))
  }
}
