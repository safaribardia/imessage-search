// Turns the generated marketing image (squircle on a white background with a
// soft drop shadow) into a proper macOS icon master: the background and shadow
// become transparent via a flood fill from the corners, the squircle is
// cropped to its bounds, and the result is re-centered at Apple's standard
// 824/1024 icon proportion on a transparent 1024x1024 canvas.
//
// Usage: swift make-appicon.swift <input.png> <output.png>

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-appicon <in.png> <out.png>\n".utf8))
    exit(1)
}

guard
    let source = NSImage(contentsOfFile: arguments[1]),
    let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("could not read \(arguments[1])\n".utf8))
    exit(1)
}

let width = cgSource.width
let height = cgSource.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
context.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))

// A pixel belongs to the background when it is bright and nearly neutral —
// this covers pure white and the soft gray drop shadow, but never the
// saturated squircle edge that encloses the artwork.
func isBackground(_ index: Int) -> Bool {
    let red = Int(pixels[index])
    let green = Int(pixels[index + 1])
    let blue = Int(pixels[index + 2])
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    return maxChannel - minChannel < 28 && minChannel > 140
}

var visited = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
for x in 0..<width {
    queue.append(x)
    queue.append((height - 1) * width + x)
}
for y in 0..<height {
    queue.append(y * width)
    queue.append(y * width + width - 1)
}

var head = 0
while head < queue.count {
    let position = queue[head]
    head += 1
    if visited[position] {
        continue
    }
    visited[position] = true
    guard isBackground(position * 4) else {
        continue
    }
    pixels[position * 4 + 3] = 0
    let x = position % width
    let y = position / width
    if x > 0 { queue.append(position - 1) }
    if x < width - 1 { queue.append(position + 1) }
    if y > 0 { queue.append(position - width) }
    if y < height - 1 { queue.append(position + width) }
}

// Bounding box of what survived the fill.
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] != 0 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("flood fill removed everything\n".utf8))
    exit(1)
}

guard
    let cleaned = context.makeImage(),
    let cropped = cleaned.cropping(to: CGRect(
        x: minX,
        // CGImage cropping is in top-left coordinates matching the buffer.
        y: height - 1 - maxY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    ))
else {
    exit(1)
}

let canvas = 1024
let shapeSize = 824
guard let output = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: canvas * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
output.interpolationQuality = .high
let inset = CGFloat(canvas - shapeSize) / 2
output.draw(cropped, in: CGRect(
    x: inset,
    y: inset,
    width: CGFloat(shapeSize),
    height: CGFloat(shapeSize)
))

guard
    let final = output.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[2]) as CFURL,
        "public.png" as CFString,
        1,
        nil
    )
else {
    exit(1)
}
CGImageDestinationAddImage(destination, final, nil)
guard CGImageDestinationFinalize(destination) else {
    exit(1)
}
print("wrote \(arguments[2]) (\(maxX - minX + 1)x\(maxY - minY + 1) shape)")
