import SwiftUI

/// The Bots floating around the welcome screens (0.9.9). Each one drifts, bobs and blinks on its own clock,
/// pops in when the screen appears, and squishes when tapped. With Reduce Motion they sit still.
struct CharacterCrowd: View {
    struct Member: Identifiable {
        let id: Int
        let shape: String
        let color: String
        /// Center as a fraction of the container. Values past 0 or 1 hang off the edge on purpose.
        let x: CGFloat
        let y: CGFloat
        let scale: CGFloat
        let tilt: Double
    }

    /// A ring around the middle, leaving the center free for a title.
    static let ring: [Member] = [
        Member(id: 0, shape: "cloud", color: "green", x: 0.36, y: 0.15, scale: 1.0, tilt: -8),
        Member(id: 1, shape: "circle", color: "pink", x: 0.73, y: 0.18, scale: 0.82, tilt: 0),
        Member(id: 2, shape: "droplet", color: "purple", x: 0.07, y: 0.33, scale: 0.78, tilt: 12),
        Member(id: 3, shape: "pebble", color: "ochre", x: 0.94, y: 0.32, scale: 0.84, tilt: -6),
        Member(id: 4, shape: "capsule", color: "amber", x: -0.02, y: 0.55, scale: 1.12, tilt: 70),
        Member(id: 5, shape: "heart", color: "red", x: 1.02, y: 0.52, scale: 1.06, tilt: -14),
        Member(id: 6, shape: "square", color: "blue", x: 0.19, y: 0.76, scale: 0.86, tilt: 0),
        Member(id: 7, shape: "flower", color: "teal", x: 0.85, y: 0.71, scale: 0.84, tilt: 10),
        Member(id: 8, shape: "hexagon", color: "orange", x: 0.53, y: 0.83, scale: 1.04, tilt: 4),
        Member(id: 9, shape: "sparkle", color: "purple", x: 0.1, y: 0.95, scale: 0.6, tilt: -10),
        Member(id: 10, shape: "clover", color: "gray", x: 0.9, y: 0.95, scale: 0.56, tilt: 18),
    ]

    private struct Squish { var x = 1.0; var y = 1.0 }

    var members: [Member] = CharacterCrowd.ring
    /// Character size as a fraction of the container's shorter side.
    var sizeFactor: CGFloat = 0.15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pokes: [Int: Int] = [:]

    var body: some View {
        GeometryReader { proxy in
            let base = min(proxy.size.width, proxy.size.height) * sizeFactor
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(members) { member in
                        character(member, base: base, t: t)
                            .position(x: member.x * proxy.size.width + drift(member, t).width * base,
                                      y: member.y * proxy.size.height + drift(member, t).height * base)
                    }
                }
            }
        }
        .onAppear { appeared = true }
        .sensoryFeedback(.impact(weight: .light), trigger: pokes)
        .accessibilityHidden(true)
    }

    private func character(_ member: Member, base: CGFloat, t: TimeInterval) -> some View {
        let wobble = reduceMotion ? 0 : sin(t * 0.6 + Double(member.id)) * 4
        return BotGlyphFace(shape: member.shape, color: member.color, size: base * member.scale,
                            blink: reduceMotion ? 1 : blink(member, t))
            .rotationEffect(.degrees(member.tilt + wobble))
            .keyframeAnimator(initialValue: Squish(), trigger: pokes[member.id, default: 0]) { view, squish in
                view.scaleEffect(x: squish.x, y: squish.y, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    SpringKeyframe(1.18, duration: 0.12)
                    SpringKeyframe(0.9, duration: 0.16)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.y) {
                    SpringKeyframe(0.8, duration: 0.12)
                    SpringKeyframe(1.14, duration: 0.16)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.3)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.62).delay(Double(member.id) * 0.045), value: appeared)
            .contentShape(Circle())
            .onTapGesture { pokes[member.id, default: 0] += 1 }
    }

    /// A slow figure-eight per character, in units of the base size.
    private func drift(_ member: Member, _ t: TimeInterval) -> CGSize {
        guard !reduceMotion else { return .zero }
        let seed = Double(member.id)
        return CGSize(width: sin(t * 0.32 + seed * 1.7) * 0.09, height: cos(t * 0.47 + seed * 2.3) * 0.12)
    }

    /// Eyes close for about 0.15 s every few seconds, each character on its own rhythm.
    private func blink(_ member: Member, _ t: TimeInterval) -> CGFloat {
        let period = 4.2 + Double(member.id % 4) * 1.3
        let phase = (t + Double(member.id) * 0.77).truncatingRemainder(dividingBy: period)
        guard phase < 0.15 else { return 1 }
        return CGFloat(1 - sin(phase / 0.15 * .pi) * 0.92)
    }
}
