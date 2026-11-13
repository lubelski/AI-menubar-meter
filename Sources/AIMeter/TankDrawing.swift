import AIMeterCore
import AppKit
import SwiftUI

/// What one tank shows. The menu bar icon and the panel both draw from this value.
enum TankFill: Equatable {
    /// A current reading. The level is solid, and turns orange and then red as it runs low.
    case live(remaining: Double, level: UsageLevel)
    /// The last reading, which is no longer current. The level is striped and never colored,
    /// so it can't be mistaken for a current reading or for an empty tank.
    case lastKnown(remaining: Double)
    /// Reading the account failed and there is no earlier reading. A dashed outline.
    case unavailable
    /// The first reading hasn't arrived yet. A faint outline.
    case waiting

    init(_ slot: TankSlot, condition: AccountState.Condition) {
        guard let tank = slot.tank else {
            self = condition == .waiting ? .waiting : .unavailable
            return
        }
        self = condition == .live
            ? .live(remaining: tank.remaining, level: tank.level)
            : .lastKnown(remaining: tank.remaining)
    }

    var remaining: Double? {
        switch self {
        case .live(let remaining, _), .lastKnown(let remaining): remaining
        case .unavailable, .waiting: nil
        }
    }

    func with(remaining: Double) -> TankFill {
        switch self {
        case .live(_, let level): .live(remaining: remaining, level: level)
        case .lastKnown: .lastKnown(remaining: remaining)
        case .unavailable, .waiting: self
        }
    }

    /// True when the tank draws in orange or red, so the menu bar image can't be a template.
    var isColored: Bool {
        if case .live(_, let level) = self { level != .normal } else { false }
    }
}

/// Draws a tank with Core Graphics. The menu bar icon and the panel call the same code
/// at different sizes, so a tank looks the same in both places.
enum TankDrawing {
    /// Width in the menu bar. Session < weekly < pool, so each kind is recognizable by shape alone.
    /// Fable is a weekly window too, so it has the weekly width and sits right after Weekly.
    static func width(for kind: Tank.Kind) -> CGFloat {
        switch kind {
        case .session: 3
        case .weekly, .fable: 4.5
        case .pool: 7
        }
    }

    /// - Parameters:
    ///   - ink: The monochrome color for tracks, outlines, and normal levels.
    ///   - flipped: True when the context's y axis points down, as in a SwiftUI `Canvas`.
    ///   - stripe: Thickness of each stripe of an out-of-date level. The same for every
    ///     tank at one size, so neighboring tanks have matching stripes.
    static func draw(
        _ fill: TankFill, in rect: CGRect, context: CGContext, ink: CGColor, flipped: Bool, stripe: CGFloat = 1
    ) {
        // Slightly rounded rectangles, not pills: the corners soften without eating the level.
        let radius = min(rect.width / 3, 5)
        let track = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let line = max(1, rect.width / 6)

        func strokeOutline(_ color: CGColor, dash: [CGFloat] = []) {
            let inset = rect.insetBy(dx: line / 2, dy: line / 2)
            let insetRadius = max(radius - line / 2, 0)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil))
            context.setStrokeColor(color)
            context.setLineWidth(line)
            context.setLineDash(phase: 0, lengths: dash)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        /// The part of the track below the level.
        func levelRect(_ remaining: Double) -> CGRect {
            // Keep a sliver visible for tiny values so "almost empty" reads differently from empty.
            let height = max(rect.height * remaining, rect.height * 0.1)
            return CGRect(x: rect.minX, y: flipped ? rect.maxY - height : rect.minY, width: rect.width, height: height)
        }

        switch fill {
        case .waiting:
            strokeOutline(ink.copy(alpha: 0.35) ?? ink)

        case .unavailable:
            strokeOutline(ink.copy(alpha: 0.6) ?? ink, dash: [line * 2, line * 1.5])

        case .live(let remaining, let level):
            let color: CGColor = switch level {
            case .normal: ink
            case .warning: NSColor.systemOrange.cgColor
            case .critical: NSColor.systemRed.cgColor
            }
            context.addPath(track)
            // A tank that is nearly empty has a red track too, so it reads as red even at 0%.
            context.setFillColor(level == .critical ? (color.copy(alpha: 0.3) ?? color) : (ink.copy(alpha: 0.24) ?? ink))
            context.fillPath()
            if level == .critical { strokeOutline(color) }
            guard remaining > 0 else { return }
            context.saveGState()
            context.addPath(track)
            context.clip()
            context.setFillColor(color)
            context.fill(levelRect(remaining))
            context.restoreGState()

        case .lastKnown(let remaining):
            context.addPath(track)
            context.setFillColor(ink.copy(alpha: 0.16) ?? ink)
            context.fillPath()
            guard remaining > 0 else { return }
            let level = levelRect(remaining)
            context.saveGState()
            context.addPath(track)
            context.clip()
            context.clip(to: level)
            context.setFillColor(ink.copy(alpha: 0.6) ?? ink)
            // Stripes start at the bottom of the tank in both coordinate systems.
            var offset: CGFloat = 0
            while offset < level.height {
                let y = flipped ? rect.maxY - offset - stripe : rect.minY + offset
                context.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: stripe))
                offset += stripe * 2
            }
            context.restoreGState()
        }
    }

    /// A tick across the tank where the level would be if usage were spread evenly over the window.
    static func drawPace(_ evenRemaining: Double, across rect: CGRect, context: CGContext, ink: CGColor, flipped: Bool) {
        let thickness: CGFloat = 1.5
        let offset = rect.height * evenRemaining
        let y = (flipped ? rect.maxY - offset : rect.minY + offset) - thickness / 2
        let tick = CGRect(x: rect.minX - 2, y: y, width: rect.width + 4, height: thickness)
        context.addPath(CGPath(roundedRect: tick, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
        context.setFillColor(ink.copy(alpha: 0.55) ?? ink)
        context.fillPath()
    }
}

/// The panel's tank: the menu bar drawing at twice the width.
struct TankView: View, @preconcurrency Animatable {
    var fill: TankFill
    let kind: Tank.Kind
    /// Portion of the window that has elapsed, for the pace tick. `nil` hides the tick.
    var elapsed: Double?
    var height: CGFloat = 64

    @Environment(\.colorScheme) private var colorScheme

    /// Lets SwiftUI animate the level when a new reading arrives.
    var animatableData: Double {
        get { fill.remaining ?? 0 }
        set { fill = fill.with(remaining: newValue) }
    }

    /// Room on each side for the pace tick, which is wider than the tank.
    private static let margin: CGFloat = 2

    var body: some View {
        let width = TankDrawing.width(for: kind) * 2
        let ink: CGColor = colorScheme == .dark ? .white : .black
        Canvas { context, size in
            let rect = CGRect(x: Self.margin, y: 0, width: size.width - 2 * Self.margin, height: size.height)
            context.withCGContext { cg in
                TankDrawing.draw(fill, in: rect, context: cg, ink: ink, flipped: true, stripe: 2)
                if let elapsed, fill.remaining != nil {
                    TankDrawing.drawPace(1 - elapsed, across: rect, context: cg, ink: ink, flipped: true)
                }
            }
        }
        .frame(width: width + 2 * Self.margin, height: height)
        .help(elapsed.map { "Even pace: \(Int(($0 * 100).rounded()))% of the window has elapsed" } ?? "")
    }
}
