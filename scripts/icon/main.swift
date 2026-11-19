// Draws the app icon's artwork with the app's own tank drawing, so the icon matches the
// About tab and the panel. scripts/render-icon.sh compiles this with TankDrawing.swift.
import AIMeterCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])

// Icon Composer's macOS canvas is 1024 points. The tanks are drawn at the About tab's
// size, then scaled up, so their corners and proportions stay the same.
let canvas = 1024
let scale: CGFloat = 10
let height: CGFloat = 56
let spacing: CGFloat = 6
let tanks: [(TankFill, Tank.Kind)] = [
    (.live(remaining: 0.75, level: .normal), .session),
    (.live(remaining: 0.45, level: .normal), .weekly),
    (.live(remaining: 0.2, level: .warning), .pool),
]

let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let widths = tanks.map { TankDrawing.width(for: $0.1) * 2 }
let total = widths.reduce(0, +) + spacing * CGFloat(tanks.count - 1)
context.translateBy(x: (CGFloat(canvas) - total * scale) / 2, y: (CGFloat(canvas) - height * scale) / 2)
context.scaleBy(x: scale, y: scale)

// The dark-mode orange, the same as the About tab in dark mode.
NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
    var x: CGFloat = 0
    for ((fill, _), width) in zip(tanks, widths) {
        let rect = CGRect(x: x, y: 0, width: width, height: height)
        TankDrawing.draw(fill, in: rect, context: context, ink: .white, flipped: false, stripe: 2)
        x += width + spacing
    }
}

let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
print("Wrote \(output.path)")
