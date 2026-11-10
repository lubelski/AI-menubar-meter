import AIMeterCore
import AppKit

/// Draws the row of tanks shown in the menu bar.
///
/// While no tank is running low the image is a template, so it matches the menu
/// bar exactly like a system icon. When a tank turns orange or red, the image
/// switches to a colored one so that tank stands out.
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
    /// Space between two accounts that share a plate, such as two OpenAI accounts.
    private static let groupGap: CGFloat = 4
    private static let logoSize: CGFloat = 10
    /// Space between a logo and the first bar it labels.
    private static let logoGap: CGFloat = 2.5

    private enum Item {
        case logo(Brand)
        case gap(CGFloat)
        case tank(Tank.Kind, TankFill)

        var width: CGFloat {
            switch self {
            case .logo: logoSize
            case .gap(let width): width
            case .tank(let kind, _): TankDrawing.width(for: kind)
            }
        }
    }

    /// One brand's logo and tanks, drawn on a shared rounded plate.
    private struct Plate {
        var brand: Brand
        var items: [Item] = []

        var width: CGFloat { items.map(\.width).reduce(0, +) + 2 * platePadding }
    }

    /// Splits the accounts into one plate per run of the same brand.
    private static func layout(_ states: [AccountState], staleAfter: TimeInterval, showLogos: Bool) -> [Plate] {
        var plates: [Plate] = []
        for state in states {
            let brand = state.account.kind.brand
            if plates.last?.brand == brand {
                plates[plates.count - 1].items.append(.gap(groupGap))
            } else {
                plates.append(Plate(brand: brand, items: showLogos ? [.logo(brand), .gap(logoGap)] : []))
            }
            let condition = state.condition(staleAfter: staleAfter)
            for (index, slot) in state.slots.enumerated() {
                if index > 0 { plates[plates.count - 1].items.append(.gap(barGap)) }
                plates[plates.count - 1].items.append(.tank(slot.kind, TankFill(slot, condition: condition)))
            }
        }
        return plates
    }

    /// - Parameter states: The visible accounts, in display order.
    static func image(for states: [AccountState], staleAfter: TimeInterval, showLogos: Bool) -> NSImage {
        guard !states.isEmpty else { return placeholder }

        let plates = layout(states, staleAfter: staleAfter, showLogos: showLogos)
        let isTemplate = !plates.flatMap(\.items).contains { item in
            if case .tank(_, let fill) = item { fill.isColored } else { false }
        }
        let width = plates.map(\.width).reduce(0, +) + CGFloat(max(plates.count - 1, 0)) * plateGap

        let image = NSImage(size: NSSize(width: width, height: canvasHeight), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
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
                    case .tank(_, let fill):
                        TankDrawing.draw(fill, in: CGRect(x: x, y: platePadding, width: item.width, height: barHeight),
                                         context: context, ink: base.cgColor, flipped: false)
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
        image.accessibilityDescription = states
            .map { description(of: $0, staleAfter: staleAfter) }
            .joined(separator: ". ")
        return image
    }

    /// Shown when no account is visible, so the menu bar item never disappears.
    private static var placeholder: NSImage {
        let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "AI Meter: no accounts shown")
            ?? NSImage(size: NSSize(width: canvasHeight, height: canvasHeight))
        image.isTemplate = true
        return image
    }

    private static func description(of state: AccountState, staleAfter: TimeInterval) -> String {
        let name = state.account.name
        switch state.condition(staleAfter: staleAfter) {
        case .waiting: return "\(name) loading"
        case .unavailable: return "\(name) unavailable"
        case .live, .stale:
            let stale = state.condition(staleAfter: staleAfter) == .stale
            let tanks = state.slots.compactMap(\.tank).map { tank in
                "\(tank.title) \(Int((tank.remaining * 100).rounded())) percent left"
            }
            return "\(name)\(stale ? ", last known" : ""): " + tanks.joined(separator: ", ")
        }
    }
}
