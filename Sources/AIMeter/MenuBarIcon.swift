import AIMeterCore
import AppKit

/// Draws the row of thermometers shown in the menu bar.
///
/// While everything is in the normal range the image is a template, so it
/// matches the menu bar exactly like a system icon. When any gauge crosses a
/// threshold it switches to a colored image so the hot gauge stands out.
enum MenuBarIcon {
    private static let barHeight: CGFloat = 15
    private static let barGap: CGFloat = 2
    private static let groupGap: CGFloat = 5
    private static let canvasHeight: CGFloat = 18

    /// Session < weekly < money pool, so each kind is recognizable by shape alone.
    private static func barWidth(for kind: UsageGauge.Kind) -> CGFloat {
        switch kind {
        case .session: 3
        case .weekly: 4.5
        case .pool: 7
        }
    }

    static func image(for groups: [[UsageGauge]], style: MeterStyle) -> NSImage {
        let gauges = groups.flatMap(\.self)
        let isTemplate = gauges.allSatisfy { $0.level == .normal }

        let width = gauges.map { barWidth(for: $0.kind) }.reduce(0, +)
            + CGFloat(gauges.count - groups.count) * barGap
            + CGFloat(max(groups.count - 1, 0)) * groupGap

        let image = NSImage(size: NSSize(width: width, height: canvasHeight), flipped: false) { _ in
            var x: CGFloat = 0
            let y = (canvasHeight - barHeight) / 2
            for (groupIndex, group) in groups.enumerated() {
                if groupIndex > 0 { x += groupGap - barGap }
                for gauge in group {
                    let barWidth = barWidth(for: gauge.kind)
                    drawBar(gauge, in: NSRect(x: x, y: y, width: barWidth, height: barHeight),
                            style: style, template: isTemplate)
                    x += barWidth + barGap
                }
            }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = gauges
            .map { gauge in
                guard let used = gauge.fraction else { return "\(gauge.label) unavailable" }
                let percent = Int((style.displayed(used) * 100).rounded())
                return "\(gauge.label) \(percent) percent \(style == .used ? "used" : "left")"
            }
            .joined(separator: ", ")
        return image
    }

    private static func drawBar(_ gauge: UsageGauge, in rect: NSRect, style: MeterStyle, template: Bool) {
        let base: NSColor = template ? .black : .labelColor
        // Thin bars are full pills; the wide pool bar gets softer corners, like a tank.
        let radius = min(rect.width / 2, 2.5)
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        guard let used = gauge.fraction else {
            // No data: a faint outline so the slot stays put without implying "0%".
            base.withAlphaComponent(0.35).setStroke()
            let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: radius - 0.5, yRadius: radius - 0.5)
            inset.lineWidth = 1
            inset.stroke()
            return
        }

        base.withAlphaComponent(0.28).setFill()
        track.fill()

        let fraction = style.displayed(used)
        guard fraction > 0 else { return }
        let fillColor: NSColor = switch gauge.level {
        case .normal: base
        case .warning: .systemOrange
        case .critical: .systemRed
        }
        // Keep a sliver visible for tiny values so "some usage" reads differently from none.
        let height = max(rect.height * fraction, 1.5)
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        fillColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
