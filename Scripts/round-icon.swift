// Shape a square source image onto Apple's macOS icon grid: a 1024x1024
// canvas with the artwork in a centered 824x824 rounded rectangle
// (radius ~185.4) and transparent margins, so macOS doesn't wrap the icon
// in its own backing shape.
//
// Handles source art with its own transparent margins and non-rounded
// corner treatments (chamfers): the art is cropped to its opaque bounding
// box, the rounded rect is underpainted with the art's background color,
// and the cropped art is drawn edge-to-edge over it.
//
// Usage: swift Scripts/round-icon.swift <input.png> <output.png>
import AppKit

guard CommandLine.arguments.count == 3,
      let sourceData = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let sourceRep = NSBitmapImageRep(data: sourceData) else {
    FileHandle.standardError.write(Data("usage: round-icon.swift <input.png> <output.png>\n".utf8))
    exit(1)
}

// Opaque bounding box of the artwork.
let w = sourceRep.pixelsWide, h = sourceRep.pixelsHigh
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where (sourceRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("error: source image is fully transparent\n".utf8))
    exit(1)
}
let bboxWidth = maxX - minX + 1
let bboxHeight = maxY - minY + 1

// Background color: sampled just inside the top-center of the opaque bbox
// (chamfers/rounding only affect corners, so this is solid background).
let bg = sourceRep.colorAt(x: minX + bboxWidth / 2, y: minY + bboxHeight / 20) ?? .black

let canvas = 1024.0
let iconSize = 824.0
let radius = 185.4
let inset = (canvas - iconSize) / 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let iconRect = NSRect(x: inset, y: inset, width: iconSize, height: iconSize)
NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius).addClip()

bg.setFill()
NSBezierPath(rect: iconRect).fill()

// Draw the cropped artwork filling the rounded rect edge-to-edge. NSImage
// draw(from:) uses a bottom-left origin; bitmap pixel coords are top-down.
let source = NSImage(size: NSSize(width: w, height: h))
source.addRepresentation(sourceRep)
let cropRect = NSRect(
    x: Double(minX), y: Double(h - minY - bboxHeight),
    width: Double(bboxWidth), height: Double(bboxHeight))
source.draw(in: iconRect, from: cropRect, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
