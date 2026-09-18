// Generates a macOS app icon PNG for FastLang.
//
// Run: `swift Tools/icon/generate_icon.swift <size> <output.png>`
//
// Renders the same SF Symbol as the menu bar (`text.bubble.fill`) on a
// solid indigo background, clipped to the Big Sur squircle mask. Uses
// `ImageIO` for PNG encoding directly — `NSImage.tiffRepresentation`
// fails with `CGImageDestinationFinalize` on this SDK, so we go to
// `CGImageDestination` explicitly.

import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 3,
      let size = Int(CommandLine.arguments[1]), size > 0
else {
    FileHandle.standardError.write(Data(
        "usage: generate_icon.swift <size-in-px> <output.png>\n".utf8
    ))
    exit(2)
}
let outputPath = CommandLine.arguments[2]

let pixelSize = CGFloat(size)
let canvas = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
let cornerRadius = pixelSize * 0.2237 // Apple's macOS squircle ratio.

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Failed to create bitmap context\n".utf8))
    exit(1)
}

// Background: indigo, clipped to squircle.
let squircle = CGPath(
    roundedRect: canvas,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)
context.addPath(squircle)
context.setFillColor(CGColor(red: 0.35, green: 0.28, blue: 0.85, alpha: 1.0))
context.fillPath()

// Render the symbol through AppKit into a template image, mask it to
// white, then draw it centered on the canvas.
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
defer { NSGraphicsContext.restoreGraphicsState() }

let symbolConfig = NSImage.SymbolConfiguration(
    pointSize: pixelSize * 0.55,
    weight: .semibold
)
guard let symbol = NSImage(
    systemSymbolName: "text.bubble.fill",
    accessibilityDescription: nil
)?.withSymbolConfiguration(symbolConfig) else {
    FileHandle.standardError.write(Data("Failed to resolve SF Symbol\n".utf8))
    exit(1)
}

// White-tinted copy: draw white, then mask to the symbol's alpha.
let whiteSymbol = NSImage(size: symbol.size, flipped: false) { rect in
    NSColor.white.set()
    rect.fill()
    symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
    return true
}

let symbolRect = NSRect(
    x: (pixelSize - whiteSymbol.size.width) / 2,
    y: (pixelSize - whiteSymbol.size.height) / 2 + pixelSize * 0.015,
    width: whiteSymbol.size.width,
    height: whiteSymbol.size.height
)
whiteSymbol.draw(in: symbolRect)

guard let cgImage = context.makeImage() else {
    FileHandle.standardError.write(Data("Failed to materialize CGImage\n".utf8))
    exit(1)
}

let outURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    outURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("Failed to create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("Failed to finalize PNG\n".utf8))
    exit(1)
}

print("Wrote \(size)×\(size) → \(outputPath)")
