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
    private static let logoSize: CGFloat = 10
    /// Space between a logo and the first bar it labels.
    private static let logoGap: CGFloat = 2.5
    /// Space before a new brand's logo. Wider than `groupGap` so the logo reads as
    /// belonging to the bars after it.
    private static let brandGap: CGFloat = 7

    /// Session < weekly < money pool, so each kind is recognizable by shape alone.
    private static func barWidth(for kind: UsageGauge.Kind) -> CGFloat {
        switch kind {
        case .session: 3
        case .weekly: 4.5
        case .pool: 7
        }
    }

    /// One service's gauges. Consecutive groups with the same brand share one logo.
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

    /// Lays the groups out left to right as logos, bars, and the gaps between them.
    private static func layout(_ groups: [Group], showLogos: Bool) -> [Item] {
        var items: [Item] = []
        var previous: Brand?
        for group in groups {
            let brand = group.service.brand
            if showLogos, brand != previous {
                if previous != nil { items.append(.gap(brandGap)) }
                items += [.logo(brand), .gap(logoGap)]
            } else if previous != nil {
                items.append(.gap(groupGap))
            }
            for (index, gauge) in group.gauges.enumerated() {
                if index > 0 { items.append(.gap(barGap)) }
                items.append(.bar(gauge))
            }
            previous = brand
        }
        return items
    }

    static func image(for groups: [Group], style: MeterStyle, showLogos: Bool) -> NSImage {
        let gauges = groups.flatMap(\.gauges)
        let isTemplate = gauges.allSatisfy { $0.level == .normal }
        let items = layout(groups, showLogos: showLogos)
        let width = items.map(\.width).reduce(0, +)

        let image = NSImage(size: NSSize(width: width, height: canvasHeight), flipped: false) { _ in
            let base: NSColor = isTemplate ? .black : .labelColor
            var x: CGFloat = 0
            for item in items {
                switch item {
                case .logo(let brand):
                    let y = (canvasHeight - logoSize) / 2
                    BrandMark.draw(brand, in: NSRect(x: x, y: y, width: logoSize, height: logoSize), color: base)
                case .bar(let gauge):
                    let y = (canvasHeight - barHeight) / 2
                    drawBar(gauge, in: NSRect(x: x, y: y, width: item.width, height: barHeight),
                            style: style, template: isTemplate)
                case .gap:
                    break
                }
                x += item.width
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
