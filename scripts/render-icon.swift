#!/usr/bin/env swift
//
// Renders the app icon for the read-me, in every appearance the system
// shows it in.
//
//     swift scripts/render-icon.swift
//
// The icon itself is Apps/Shared/AppIcon.icon: three SVG layers and an
// icon.json that says how they are filled in the light, dark and tinted
// appearances. Icon Composer opens it, and so does a text editor. The glass,
// the shadows and the shape are the system's, which is why the pictures
// here are made by the tool that comes with Xcode and not drawn.
//
// Run this again after changing the icon and commit what it writes to
// docs/images.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icon = root.appending(path: "Apps/Shared/AppIcon.icon")
let images = root.appending(path: "docs/images")
let tool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

guard FileManager.default.isExecutableFile(atPath: tool) else {
    FileHandle.standardError.write(Data("Icon Composer's ictool was not found. It comes with Xcode 26 and later.\n".utf8))
    exit(1)
}

let scratch = FileManager.default.temporaryDirectory.appending(path: "openscreens-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// One picture of the icon, as the system would draw it.
func render(_ rendition: String, size: Int) throws -> CGImage {
    let file = scratch.appending(path: "\(rendition)-\(size).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [
        icon.path, "--export-image", "--output-file", file.path,
        "--platform", "macOS", "--rendition", rendition,
        "--width", "\(size)", "--height", "\(size)", "--scale", "1",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("The \(rendition) rendition could not be made.\n".utf8))
        exit(1)
    }
    return image
}

func write(_ image: CGImage, to name: String) {
    let url = images.appending(path: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote docs/images/\(name)")
}

// The icon by itself, for the top of the read-me.
write(try render("Default", size: 512), to: "icon.png")

// The appearances side by side, on something to be seen against: the clear
// and tinted ones are glass, and glass over nothing shows nothing.
let renditions = ["Default", "Dark", "TintedDark", "ClearLight"]
let cell = 256, gap = 40, margin = 48
let width = margin * 2 + renditions.count * cell + (renditions.count - 1) * gap
let height = margin * 2 + cell
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let backdrop = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
    cornerWidth: 44, cornerHeight: 44, transform: nil)
context.addPath(backdrop)
context.clip()
let colours = [
    CGColor(colorSpace: space, components: [0.36, 0.40, 0.52, 1])!,
    CGColor(colorSpace: space, components: [0.13, 0.14, 0.20, 1])!,
] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
for (index, rendition) in renditions.enumerated() {
    let image = try render(rendition, size: cell * 2)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: margin + index * (cell + gap), y: margin, width: cell, height: cell))
}
write(context.makeImage()!, to: "icon-appearances.png")
