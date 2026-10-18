#!/usr/bin/env swift
import AppKit
import Foundation

// Original, code-drawn artwork. Keep its geometry in sync with Support/AppIcon.svg.
// Rendering needs AppKit, but does not open a window or access other applications.
let output = CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon bitmap")
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}
let base = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 190, yRadius: 190)
color(35, 43, 40).setFill()
base.fill()
let edge = NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 852, height: 852), xRadius: 188, yRadius: 188)
edge.lineWidth = 4
color(211, 231, 217, alpha: 0.14).setStroke()
edge.stroke()
color(200, 227, 210).setFill()
for rect in [NSRect(x: 348, y: 480, width: 328, height: 64),
             NSRect(x: 300, y: 326, width: 96, height: 372),
             NSRect(x: 628, y: 238, width: 96, height: 548)] {
    NSBezierPath(roundedRect: rect, xRadius: min(rect.width, rect.height) / 2,
                 yRadius: min(rect.width, rect.height) / 2).fill()
}
color(244, 240, 232).setFill()
NSBezierPath(ovalIn: NSRect(x: 466, y: 466, width: 92, height: 92)).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print(output)
