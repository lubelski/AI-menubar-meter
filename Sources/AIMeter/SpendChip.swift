import AIMeterCore
import AppKit
import SwiftUI

/// What one spend chip shows. The menu bar icon and the panel both draw from this value.
/// The cases match `TankFill`, so an account reads the same way whichever one it has.
enum SpendFill: Equatable {
    /// A current amount. It turns orange and then red as it passes the account's thresholds.
    case live(dollars: Double, level: UsageLevel)
    /// The last amount read, which is no longer current. Dimmed and never colored.
    case lastKnown(dollars: Double)
    /// Reading the account failed and there is no earlier amount. A dashed outline.
    case unavailable
    /// The first reading hasn't arrived yet. A faint outline.
    case waiting

    init(_ state: AccountState, condition: AccountState.Condition) {
        guard let spend = state.spend else {
            self = condition == .waiting ? .waiting : .unavailable
            return
        }
        self = condition == .live
            ? .live(dollars: spend.today, level: state.account.spendLevel(spend.today))
            : .lastKnown(dollars: spend.today)
    }

    var text: String {
        switch self {
        case .live(let dollars, _), .lastKnown(let dollars): CompactDollars.string(dollars)
        case .unavailable, .waiting: "$–"
        }
    }

    /// True when the chip draws in orange or red, so the menu bar image can't be a template.
    var isColored: Bool {
        if case .live(_, let level) = self { level != .normal } else { false }
    }
}

/// Draws an amount of money in a rounded box the height of a tank. An account that bills
/// by use has no limit to drain, so it shows this in place of tanks.
enum SpendChip {
    /// Sizes that scale with the chip's height. The menu bar draws at 14 pt and the panel at twice that.
    private static func fontSize(_ height: CGFloat) -> CGFloat { (height * 0.64).rounded() }
    private static func padding(_ height: CGFloat) -> CGFloat { height * 0.2 }
    private static func radius(_ height: CGFloat) -> CGFloat { height * 0.2 }

    private static func font(_ height: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: fontSize(height), weight: .semibold)
    }

    static func width(for fill: SpendFill, height: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: fill.text, attributes: [.font: font(height)])
        return ceil(text.size().width) + 2 * padding(height)
    }

    /// Draws into the current graphics context, whose y axis must point up.
    static func draw(_ fill: SpendFill, in rect: CGRect, ink: NSColor) {
        let radius = radius(rect.height)
        let line = max(1, rect.height / 14)
        let box = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        func strokeOutline(_ color: NSColor, dash: [CGFloat] = []) {
            let inset = rect.insetBy(dx: line / 2, dy: line / 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: radius - line / 2, yRadius: radius - line / 2)
            path.lineWidth = line
            if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
            color.setStroke()
            path.stroke()
        }

        let textColor: NSColor
        switch fill {
        case .waiting:
            strokeOutline(ink.withAlphaComponent(0.35))
            textColor = ink.withAlphaComponent(0.35)

        case .unavailable:
            strokeOutline(ink.withAlphaComponent(0.6), dash: [line * 2, line * 1.5])
            textColor = ink.withAlphaComponent(0.6)

        case .live(_, let level):
            let color: NSColor = switch level {
            case .normal: ink
            case .warning: .systemOrange
            case .critical: .systemRed
            }
            color.withAlphaComponent(level == .normal ? 0.24 : 0.3).setFill()
            box.fill()
            // Past the red threshold the chip gets a red outline, like a tank that is nearly empty.
            if level == .critical { strokeOutline(color) }
            textColor = color

        case .lastKnown:
            ink.withAlphaComponent(0.16).setFill()
            box.fill()
            textColor = ink.withAlphaComponent(0.55)
        }

        let font = font(rect.height)
        let text = NSAttributedString(string: fill.text, attributes: [.font: font, .foregroundColor: textColor])
        // Center the capital height, not the line box, so the digits sit in the middle of the chip.
        let baseline = rect.midY - font.capHeight / 2
        let x = rect.midX - text.size().width / 2
        text.draw(at: NSPoint(x: x, y: baseline + font.descender))
    }

    static func image(_ fill: SpendFill, height: CGFloat) -> NSImage {
        let size = NSSize(width: width(for: fill, height: height), height: height)
        return NSImage(size: size, flipped: false) { rect in
            draw(fill, in: rect, ink: .labelColor)
            return true
        }
    }
}

/// The panel's chip: the menu bar drawing at twice the size.
struct SpendChipView: View {
    let fill: SpendFill
    var height: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: SpendChip.image(fill, height: height))
            // The image resolves its colors when it draws. A new identity redraws it when the appearance changes.
            .id(colorScheme)
            .accessibilityHidden(true)
    }
}
