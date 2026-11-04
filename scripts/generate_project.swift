// Optional icon renderer: swift scripts/generate_project.swift
// Run from the Pulso project root; uses only macOS system frameworks.
import AppKit

let size = CGSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.05, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
let glow = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.19, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.05, alpha: 1))!
glow.draw(in: NSBezierPath(ovalIn: CGRect(x: 40, y: 60, width: 944, height: 904)), relativeCenterPosition: .zero)
let pulse = NSBezierPath()
pulse.move(to: CGPoint(x: 170, y: 500))
for point in [CGPoint(x: 330, y: 500), CGPoint(x: 410, y: 675), CGPoint(x: 530, y: 325), CGPoint(x: 625, y: 550), CGPoint(x: 685, y: 500), CGPoint(x: 854, y: 500)] { pulse.line(to: point) }
pulse.lineWidth = 58
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
NSColor(calibratedRed: 0.57, green: 0.95, blue: 0.78, alpha: 1).setStroke()
pulse.stroke()
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: url)
print("Rendered \(url.path)")
