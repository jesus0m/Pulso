// Recreate the app icon: swift scripts/generate_project.swift
// Uses an explicit Core Graphics bitmap so drawing is committed before PNG export.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 1024
let height = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.035, 0.045, 0.05, 1])!)
context.fill(bounds)

context.saveGState()
context.addEllipse(in: CGRect(x: 40, y: 60, width: 944, height: 904))
context.clip()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(colorSpace: colorSpace, components: [0.12, 0.23, 0.19, 1])!,
    CGColor(colorSpace: colorSpace, components: [0.035, 0.045, 0.05, 1])!
] as CFArray, locations: [0, 1])!
context.drawRadialGradient(gradient, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512), endRadius: 472,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
context.restoreGState()

context.move(to: CGPoint(x: 170, y: 500))
for point in [CGPoint(x: 330, y: 500), CGPoint(x: 410, y: 675),
              CGPoint(x: 530, y: 325), CGPoint(x: 625, y: 550),
              CGPoint(x: 685, y: 500), CGPoint(x: 854, y: 500)] {
    context.addLine(to: point)
}
context.setLineWidth(58)
context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.57, 0.95, 0.78, 1])!)
context.strokePath()

let url = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let image = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create app icon image")
}
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Could not write app icon PNG") }
print("Rendered opaque sRGB app icon: \(url.path)")
