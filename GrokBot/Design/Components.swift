import SwiftUI

enum Palette {
    static let background = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let userBubble = Color(uiColor: .systemGray4)
    static func bot(_ name: String) -> Color {
        switch name {
        case "purple": Color(red: 0.57, green: 0.32, blue: 1)
        case "pink": Color(red: 1, green: 0.16, blue: 0.6)
        case "ochre": Color(red: 0.64, green: 0.43, blue: 0.23)
        default: Color.primary
        }
    }
}

/// Original vector artwork. No proprietary assets are bundled.
struct BotAvatar: View {
    var color = "white"
    var size: CGFloat = 48
    var appearance: BotAppearance? = nil
    var body: some View {
        Group {
            if let appearance {
                CustomBotAvatar(appearance: appearance, size: size)
            } else if color != "white" {
                CustomBotAvatar(appearance: BotAppearance(
                    shape: color == "pink" ? .circle : color == "ochre" ? .hexagon : .pebble,
                    color: color), size: size)
            } else {
                ZStack {
                    Circle().fill(Color.primary)
                    HStack(spacing: size * 0.12) {
                        Capsule().frame(width: size * 0.1, height: size * 0.25)
                        Capsule().frame(width: size * 0.09, height: size * 0.23).offset(y: -size * 0.035)
                    }
                    .foregroundStyle(Palette.background).rotationEffect(.degrees(-28))
                    .offset(x: size * 0.12, y: -size * 0.12)
                }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PreviewBanner: View {
    var body: some View {
        Label("DESKTOP HOST REQUIRED", systemImage: "iphone.slash")
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Palette.card)
            .accessibilityLabel("Desktop host connection required for AI chat on iPhone.")
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    @State private var taps = 0
    var body: some View {
        Button { taps += 1; action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .glassChrome(in: Circle())
                .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
        }
        .buttonStyle(PressableTileStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
    }
}

struct StatusCard: View {
    var title: String
    var detail: String
    var symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}

// MARK: 0.9.2 chat parts

extension Palette {
    static let working = Color(red: 0.63, green: 0.48, blue: 1)
    static let attention = Color(red: 1, green: 0.62, blue: 0.04)
    static let quiet = Color(uiColor: .tertiaryLabel)
    /// 10.2: the thin edge cards and pills share.
    static let hairline = Color.primary.opacity(0.06)
}

/// Three dots that breathe in turn while a Bot has not written anything yet.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.2) % 4
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 0.7 : (step == index ? 1 : 0.3))
                }
            }
        }
        .accessibilityElement().accessibilityLabel("Thinking")
    }
}

/// One tool step (read a page, ran a command, saved a memory) as a small pill. Tap to see the full result.
struct ActivityPill: View {
    let text: String
    var routine = false
    @State private var expanded = false
    private var firstLine: String { text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text }
    private var summary: String {
        var line = firstLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Linux VM result") { return "Ran a command in the Linux VM" }
        if line.hasPrefix("Queued message · ") { return "Asked " + String(line.dropFirst("Queued message · ".count)) }
        line = line.replacingOccurrences(of: " (untrusted context)", with: "")
        if line.hasSuffix(":") { line.removeLast() }
        return routine ? "Routine · " + line : line
    }
    private var hasMore: Bool { text.contains("\n") || text.count > 90 }
    private var icon: String {
        let lower = firstLine.lowercased()
        if routine { return "clock" }
        if lower.contains("vm") { return "terminal" }
        if lower.hasPrefix("read ") || lower.contains("page") || lower.contains("browser") { return "globe" }
        if lower.contains("memory") { return "brain" }
        if lower.contains("message") { return "paperplane" }
        if lower.contains("couldn") || lower.contains("could not") || lower.contains("declined") { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if hasMore { withAnimation(.snappy) { expanded.toggle() } } } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2.weight(.semibold))
                    Text(summary).lineLimit(1)
                    if hasMore { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(expanded ? 90 : 0)) }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Palette.card, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }.buttonStyle(PressableTileStyle())
            if expanded {
                Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Activity: \(summary)")
    }
}

/// A question a Bot asked with a short list of answers.
struct QuestionCard: View {
    let prompt: ChoicePrompt
    let canAnswer: Bool
    let answer: (String) -> Void
    let other: () -> Void
    @State private var picked: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(canAnswer ? (prompt.multiple ? "Choose any that apply" : "Choose one") : "Answered",
                  systemImage: prompt.multiple ? "checklist" : "questionmark.bubble")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.bottom, 2)
            ForEach(prompt.options, id: \.self) { option in
                Button {
                    guard canAnswer else { return }
                    if prompt.multiple {
                        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
                    } else { answer(option) }
                } label: {
                    HStack(spacing: 10) {
                        if prompt.multiple {
                            Image(systemName: picked.contains(option) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(option) ? Color.primary : Color.secondary)
                        }
                        Text(option).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.body).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.buttonStyle(PressableTileStyle())
            }
            if canAnswer {
                HStack {
                    Button("Something else…") { other() }.font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if prompt.multiple {
                        Button { answer(prompt.options.filter { picked.contains($0) }.joined(separator: ", ")) } label: {
                            Text("Submit").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.background)
                                .padding(.horizontal, 16).padding(.vertical, 8).background(Color.primary, in: Capsule())
                        }.buttonStyle(.plain).disabled(picked.isEmpty).opacity(picked.isEmpty ? 0.4 : 1)
                    }
                }.padding(.horizontal, 4).padding(.top, 4)
            }
        }
        .padding(10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .opacity(canAnswer ? 1 : 0.6)
    }
}

/// The computer is waiting for your OK on something a Bot wants to do. Shown as a card, not an alert.
struct PhoneApprovalCard: View {
    let request: RemoteApproval
    let answer: (Bool) -> Void
    @State private var answered: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Needs your OK", systemImage: "hand.raised.fill").font(.caption.weight(.semibold)).foregroundStyle(Palette.attention)
            Text(request.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
                .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 10) {
                Button { answered = false; answer(false) } label: {
                    Text("Deny").font(.body.weight(.medium)).frame(maxWidth: .infinity).frame(height: 46)
                        .background(Color.primary.opacity(0.08), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(PressableTileStyle())
                Button { answered = true; answer(true) } label: {
                    Text("Allow once").font(.body.weight(.semibold)).foregroundStyle(Palette.background)
                        .frame(maxWidth: .infinity).frame(height: 46).background(Color.primary, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(PressableTileStyle())
            }
            .sensoryFeedback(trigger: answered) { _, new in new == true ? .success : new == false ? .warning : nil }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Palette.attention.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Press feedback (10.1)
// Apple's fluid-interface rule: respond on touch-down, not on release, and let go with a critically damped spring.

/// A list row that highlights the instant a finger lands and settles back with a spring.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableRowBody(configuration: configuration)
    }
    private struct PressableRowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0)).padding(.horizontal, 10))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.35, dampingFraction: 1), value: configuration.isPressed)
        }
    }
}

/// A tile (a pinned Bot) that shrinks slightly under the finger and springs back.
struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableTileBody(configuration: configuration)
    }
    private struct PressableTileBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.35, dampingFraction: 0.8), value: configuration.isPressed)
        }
    }
}
