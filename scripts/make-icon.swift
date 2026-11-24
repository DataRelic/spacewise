// Regenerates assets/AppIcon.icns, the icon in the app bundle.
//
//     swift scripts/make-icon.swift
//
// Needs only the Swift toolchain and `iconutil`, which ships with macOS. The result is committed, so a normal build
// needs neither.
//
// Draws the same treemap as assets/icon.svg, with a transparent margin for macOS.

import AppKit
import Foundation

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1)
}

/// The icon at exactly `pixels` by `pixels` device pixels, with transparent corners and margin.
func renderIcon(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fail("could not create a \(pixels) pixel bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let side = CGFloat(pixels)
    let body = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side / 16, dy: side / 16)
    color(0x174a9f).setFill()
    NSBezierPath(roundedRect: body, xRadius: body.width * 27 / 112, yRadius: body.width * 27 / 112).fill()
    let tiles: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: UInt32)] = [
        (20, 21, 45, 32, 0xe6f8ff),
        (71, 21, 21, 32, 0xabdfff),
        (20, 59, 26, 32, 0x72d6fc),
        (52, 59, 40, 32, 0x72d6fc),
    ]
    let unit = body.width / 112
    for tile in tiles {
        let frame = NSRect(
            x: body.minX + tile.x * unit, y: body.maxY - (tile.y + tile.height) * unit,
            width: tile.width * unit, height: tile.height * unit)
        color(tile.color).setFill()
        frame.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("could not encode a PNG") }
    return png
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let scripts = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
let output = scripts.deletingLastPathComponent().appendingPathComponent("assets/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("spacewise-icon-\(UUID().uuidString).iconset")
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    // The names and sizes iconutil expects: each point size at 1x and 2x.
    for points in [16, 32, 128, 256, 512] {
        try renderIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try renderIcon(pixels: points * 2)
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }

    let converter = Process()
    converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    converter.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try converter.run()
    converter.waitUntilExit()
    guard converter.terminationStatus == 0 else { fail("iconutil exited with status \(converter.terminationStatus)") }
} catch {
    fail("\(error)")
}
print("wrote \(output.path)")
