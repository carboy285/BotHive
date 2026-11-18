import SwiftUI

/// A Bot's drawn face: a colored shape with two capsule eyes. Depends on SwiftUI only, so the iPhone app,
/// the Mac app and the Live Activity extension all share one drawing (0.9.9).
enum BotGlyph {
    static let colors: [String: UInt32] = ["black": 0x111111, "ochre": 0xA46E39, "red": 0xFF2948,
        "orange": 0xFF7012, "amber": 0xF69A0A, "green": 0x10BF70, "teal": 0x15B6A5,
        "blue": 0x2385FF, "purple": 0x9355FF, "pink": 0xF62A9B, "gray": 0x969696, "white": 0xFFFFFF]

    static func color(_ name: String) -> Color {
        let hex = colors[name] ?? 0x9355FF
        return Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }

    /// Eye color that reads on the given body color.
    static func ink(_ name: String) -> Color { name == "white" ? .black : .white }
}

/// The face without an uploaded image. `blink` scales the eyes vertically (1 open, about 0.1 shut).
struct BotGlyphFace: View {
    var shape: String
    var color: String
    var size: CGFloat
    var blink: CGFloat = 1
    var body: some View {
        ZStack {
            BotGlyphShape(style: shape).fill(BotGlyph.color(color))
            HStack(spacing: size * 0.115) {
                Capsule().frame(width: size * 0.09, height: size * 0.25)
                Capsule().frame(width: size * 0.09, height: size * 0.25).offset(y: -size * 0.035)
            }
            .scaleEffect(x: 1, y: max(0.08, blink), anchor: .center)
            .foregroundStyle(BotGlyph.ink(color))
            .rotationEffect(.degrees(-25)).offset(x: size * 0.07, y: -size * 0.06)
            if shape == "fruit" {
                Capsule().fill(Color.primary).frame(width: size * 0.08, height: size * 0.17)
                    .rotationEffect(.degrees(-35)).offset(x: -size * 0.12, y: -size * 0.42)
            }
        }
        .padding(size * 0.04)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shape names match `BotAvatarShape` raw values. Unknown names draw a circle.
struct BotGlyphShape: Shape {
    let style: String
    func path(in rect: CGRect) -> Path {
        if style == "circle" || style == "fruit" { return Circle().path(in: rect) }
        if style == "square" { return RoundedRectangle(cornerRadius: rect.width * 0.13, style: .continuous).path(in: rect).applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(rotationAngle: -.pi / 9)).concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))) }
        if style == "capsule" { return Capsule().path(in: rect.insetBy(dx: 0, dy: rect.height * 0.12)) }
        if style == "heart" {
            var path = Path()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
            path.move(to: p(0.5, 0.94))
            path.addCurve(to: p(0.04, 0.3), control1: p(0.1, 0.75), control2: p(-0.1, 0.55))
            path.addCurve(to: p(0.5, 0.22), control1: p(0.1, -0.02), control2: p(0.4, 0.01))
            path.addCurve(to: p(0.96, 0.3), control1: p(0.6, 0.01), control2: p(0.9, -0.02))
            path.addCurve(to: p(0.5, 0.94), control1: p(1.1, 0.55), control2: p(0.9, 0.75))
            path.closeSubpath(); return path
        }
        let count = 120
        let points: [CGPoint] = (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
            let radius: Double
            switch style {
            case "hexagon":
                let sector = (angle + 2 * .pi).truncatingRemainder(dividingBy: .pi / 3) - .pi / 6
                radius = 0.42 / cos(sector)
            case "triangle": radius = 0.37 + 0.105 * cos(3 * angle)
            case "sparkle": radius = 0.37 + 0.11 * cos(4 * angle)
            case "star": radius = 0.37 + 0.105 * cos(6 * angle)
            case "flower": radius = 0.41 + 0.07 * cos(5 * angle)
            case "clover": radius = 0.40 + 0.085 * cos(4 * angle + 0.6)
            case "cloud": radius = 0.42 + 0.055 * cos(7 * angle) + 0.025 * sin(3 * angle)
            case "droplet": radius = 0.39 + 0.08 * cos(angle) + 0.055 * cos(3 * angle)
            case "pebble": radius = 0.43 + 0.035 * cos(3 * angle) + 0.025 * sin(2 * angle)
            default: radius = 0.46
            }
            return CGPoint(x: rect.midX + rect.width * CGFloat(radius * cos(angle)),
                           y: rect.midY + rect.height * CGFloat(radius * sin(angle)))
        }
        var path = Path(); path.addLines(points); path.closeSubpath(); return path
    }
}
