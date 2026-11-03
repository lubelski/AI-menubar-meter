import AIMeterCore
import AppKit

/// Small monochrome marks that label each group of meters.
///
/// These are simplified drawings sized for a 9–12 pt slot, not the official artwork.
/// They only need to be told apart at a glance next to the bars.
enum BrandMark {
    /// Draws the mark filling `rect`, in the current fill and stroke color.
    static func draw(_ brand: Brand, in rect: NSRect, color: NSColor) {
        switch brand {
        case .anthropic: drawSpark(in: rect, color: color)
        case .openAI: drawKnot(in: rect, color: color)
        }
    }

    /// A template image for SwiftUI, so the mark takes the surrounding foreground style.
    static func image(_ brand: Brand, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(brand, in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = brand.title
        return image
    }

    /// Claude's starburst: rays of alternating length from the center.
    private static func drawSpark(in rect: NSRect, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width / 2
        let rays = 10
        let path = NSBezierPath()
        path.lineWidth = max(rect.width * 0.13, 1)
        path.lineCapStyle = .round
        for index in 0..<rays {
            let angle = CGFloat(index) / CGFloat(rays) * 2 * .pi + .pi / 2
            let length = (index.isMultiple(of: 2) ? 1 : 0.72) * (outer - path.lineWidth / 2)
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
        }
        color.setStroke()
        path.stroke()
    }

    /// OpenAI's knot, reduced to six rounded links turned 60° apart around a hexagon.
    private static func drawKnot(in rect: NSRect, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let lineWidth = max(rect.width * 0.1, 0.9)
        let radius = rect.width / 2 - lineWidth / 2
        let linkWidth = radius * 0.62
        let linkLength = radius * 1.05
        let path = NSBezierPath()
        for index in 0..<6 {
            let link = NSBezierPath(
                roundedRect: NSRect(x: -linkWidth / 2, y: radius - linkLength, width: linkWidth, height: linkLength),
                xRadius: linkWidth / 2, yRadius: linkWidth / 2)
            var transform = AffineTransform(translationByX: center.x, byY: center.y)
            transform.rotate(byDegrees: CGFloat(index) * 60 + 30)
            transform.translate(x: radius * 0.22, y: 0)
            link.transform(using: transform)
            path.append(link)
        }
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}
