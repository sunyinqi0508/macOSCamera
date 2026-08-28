#!/usr/bin/env swift
// Generates the app icon (AppIcon.icns) — a macOS-style rounded tile with a
// camera glyph and the app's yellow accent. Run:
//   swift scripts/generate_app_icon.swift Resources/AppIcon.icns

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: generate_app_icon.swift <output.icns>\n", stderr)
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Big Sur icon grid: the tile leaves a transparent margin inside the canvas.
    let tileSide = canvas * 824.0 / 1024.0
    let tileRect = NSRect(
        x: (canvas - tileSide) / 2,
        y: (canvas - tileSide) / 2,
        width: tileSide,
        height: tileSide
    )
    let cornerRadius = tileSide * 0.2237
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft drop shadow behind the tile.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = canvas * 0.012
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.005)
    shadow.set()

    // Light metallic gradient, in the spirit of the system camera tile.
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.975, alpha: 1),
        ending: NSColor(calibratedRed: 0.815, green: 0.82, blue: 0.845, alpha: 1)
    )
    gradient?.draw(in: tile, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Camera body glyph.
    let glyphColor = NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
    if let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: tileSide * 0.42, weight: .regular)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        glyphColor.set()
        let rect = NSRect(origin: .zero, size: configured.size)
        configured.draw(in: rect)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let glyphWidth = tileSide * 0.56
        let glyphHeight = glyphWidth * (configured.size.height / max(configured.size.width, 1))
        let glyphRect = NSRect(
            x: tileRect.midX - glyphWidth / 2,
            y: tileRect.midY - glyphHeight / 2,
            width: glyphWidth,
            height: glyphHeight
        )
        tinted.draw(in: glyphRect)

        // Lens: a cut-out ring with the app's yellow accent at its heart.
        // camera.fill's lens sits at the glyph center, slightly below the middle.
        let lensCenter = NSPoint(x: glyphRect.midX, y: glyphRect.midY - glyphHeight * 0.06)
        let cutoutDiameter = glyphWidth * 0.30
        let cutout = NSBezierPath(ovalIn: NSRect(
            x: lensCenter.x - cutoutDiameter / 2,
            y: lensCenter.y - cutoutDiameter / 2,
            width: cutoutDiameter,
            height: cutoutDiameter
        ))
        NSColor(calibratedRed: 0.88, green: 0.885, blue: 0.905, alpha: 1).set()
        cutout.fill()

        let accentDiameter = cutoutDiameter * 0.62
        let accent = NSBezierPath(ovalIn: NSRect(
            x: lensCenter.x - accentDiameter / 2,
            y: lensCenter.y - accentDiameter / 2,
            width: accentDiameter,
            height: accentDiameter
        ))
        NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 1).set()
        accent.fill()

        let highlightDiameter = accentDiameter * 0.32
        let highlight = NSBezierPath(ovalIn: NSRect(
            x: lensCenter.x - highlightDiameter * 0.9,
            y: lensCenter.y + accentDiameter * 0.10,
            width: highlightDiameter,
            height: highlightDiameter
        ))
        NSColor.white.withAlphaComponent(0.75).set()
        highlight.fill()
    }

    return image
}

func writePNG(_ image: NSImage, side: Int, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let source = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "icon", code: 1)
    }

    let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    scaled.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = scaled.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try png.write(to: url)
}

let master = drawIcon(canvas: 1024)

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, side) in variants {
    try writePNG(master, side: side, to: iconsetURL.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)

guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("wrote \(outputURL.path)")
