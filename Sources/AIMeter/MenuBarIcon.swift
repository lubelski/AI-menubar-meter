import AIMeterCore
import AppKit

/// Draws the row of thermometers shown in the menu bar.
///
/// While everything is in the normal range the image is a template, so it
/// matches the menu bar exactly like a system icon. When any gauge crosses a
/// threshold it switches to a colored image so the hot gauge stands out.
enum MenuBarIcon {
    private static let canvasHeight: CGFloat = 18
    /// Inset between a brand's plate and the logo and bars inside it.
    private static let platePadding: CGFloat = 2
    private static let plateRadius: CGFloat = 3.5
    private static let plateOpacity: CGFloat = 0.14
    /// Space between two brands' plates.
    private static let plateGap: CGFloat = 3
    private static let barHeight = canvasHeight - 2 * platePadding
    private static let barGap: CGFloat = 2
    /// Space between two services that share a plate, such as Claude and API credit.
    private static let groupGap: CGFloat = 4
    private static let logoSize: CGFloat = 10
    /// Space between a logo and the first bar it labels.
    private static let logoGap: CGFloat = 2.5

    /// Session < weekly < money pool, so each kind is recognizable by shape alone.
    private static func barWidth(for kind: UsageGauge.Kind) -> CGFloat {
        switch kind {
        case .session: 3
        case .weekly: 4.5
        case .pool: 7
        }
    }

    /// One service's gauges. Consecutive groups with the same brand share one plate and logo.
    struct Group {
        var service: Service
        var gauges: [UsageGauge]
    }

    private enum Item {
        case logo(Brand)
        case gap(CGFloat)
        case bar(UsageGauge)

        var width: CGFloat {
            switch self {
            case .logo: logoSize
            case .gap(let width): width
            case .bar(let gauge): barWidth(for: gauge.kind)
            }
        }
    }

    /// One brand's logo and bars, drawn on a shared rounded plate.
    private struct Plate {
        var brand: Brand
        var items: [Item] = []

        var width: CGFloat { items.map(\.width).reduce(0, +) + 2 * platePadding }
    }

    /// Splits the groups into one plate per run of the same brand.
    private static func layout(_ groups: [Group], showLogos: Bool) -> [Plate] {
        var plates: [Plate] = []
        for group in groups {
            let brand = group.service.brand
            if plates.last?.brand == brand {
                plates[plates.count - 1].items.append(.gap(groupGap))
            } else {
                plates.append(Plate(brand: brand, items: showLogos ? [.logo(brand), .gap(logoGap)] : []))
            }
            for (index, gauge) in group.gauges.enumerated() {
                if index > 0 { plates[plates.count - 1].items.append(.gap(barGap)) }
                plates[plates.count - 1].items.append(.bar(gauge))
            }
        }
        return plates
    }

    static func image(for groups: [Group], style: MeterStyle, showLogos: Bool) -> NSImage {
        let gauges = groups.flatMap(\.gauges)
        let isTemplate = gauges.allSatisfy { $0.level == .normal }
        let plates = layout(groups, showLogos: showLogos)
        let width = plates.map(\.width).reduce(0, +) + CGFloat(max(plates.count - 1, 0)) * plateGap

        let image = NSImage(size: NSSize(width: width, height: canvasHeight), flipped: false) { _ in
            let base: NSColor = isTemplate ? .black : .labelColor
            var plateX: CGFloat = 0
            for plate in plates {
                let plateRect = NSRect(x: plateX, y: 0, width: plate.width, height: canvasHeight)
                base.withAlphaComponent(plateOpacity).setFill()
                NSBezierPath(roundedRect: plateRect, xRadius: plateRadius, yRadius: plateRadius).fill()

                var x = plateX + platePadding
                for item in plate.items {
                    switch item {
                    case .logo(let brand):
                        let y = (canvasHeight - logoSize) / 2
                        BrandMark.draw(brand, in: NSRect(x: x, y: y, width: logoSize, height: logoSize), color: base)
                    case .bar(let gauge):
                        drawBar(gauge, in: NSRect(x: x, y: platePadding, width: item.width, height: barHeight),
                                style: style, template: isTemplate)
                    case .gap:
                        break
                    }
                    x += item.width
                }
                plateX += plate.width + plateGap
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
        // Slightly rounded rectangles, not pills: the corners soften without eating the fill.
        let radius: CGFloat = 1
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
