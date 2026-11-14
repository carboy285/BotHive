import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// First launch on iPhone (0.9.9): the Bots say hello, then sign in, pair your Mac, and allow the microphone
/// and notifications. Every step after the welcome can be skipped, and nothing here blocks using the app.
struct OnboardingFlow: View {
    @EnvironmentObject private var remote: RemoteController
    /// Observed directly: the account publishes its own changes, not through `remote`.
    @ObservedObject var account: CloudAccount
    let done: () -> Void

    enum Step: Int, CaseIterable { case welcome, account, pair, microphone, notifications }
    @State private var step = Step.welcome
    @State private var asking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.opacity)
            default: page.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                 removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.9), value: step)
        .onChange(of: account.signedIn) { _, signedIn in if signedIn && step == .account { advance() } }
        .onChange(of: remote.hasSnapshot) { _, paired in if paired && step == .pair { advance() } }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            ZStack {
                CharacterCrowd()
                VStack(spacing: 10) {
                    Text("Grok Bot").font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                    Text("Your Bots keep working on your Mac.\nTalk to them from anywhere.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
            }
            .frame(maxHeight: .infinity)
            primary("Get started") { advance() }
                .padding(.horizontal, 24).padding(.bottom, 12)
                .accessibilityIdentifier("onboarding-start")
        }
    }

    // MARK: Steps

    private var page: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 14) {
                    hero.padding(.top, 28).padding(.bottom, 10)
                    Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.4).multilineTextAlignment(.center)
                    Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    content.padding(.top, 14)
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            bottom.padding(.horizontal, 24).padding(.bottom, 12)
        }
    }

    private var topBar: some View {
        HStack {
            Button { back() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases.dropFirst(), id: \.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Color.primary : Color.primary.opacity(0.15))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 1)")
            Spacer()
            Button("Skip") { advance() }.font(.body).foregroundStyle(.secondary).frame(width: 44, height: 44)
                .accessibilityIdentifier("onboarding-skip")
        }
        .padding(.horizontal, 12)
    }

    private var hero: some View {
        let look: (shape: String, color: String) = switch step {
        case .account: ("cloud", "green")
        case .pair: ("square", "blue")
        case .microphone: ("hexagon", "orange")
        default: ("circle", "pink")
        }
        return HeroCharacter(shape: look.shape, color: look.color).id(step)
    }

    private var title: String {
        switch step {
        case .account: account.signedIn ? "You’re signed in" : "Sign in"
        case .pair: remote.hasSnapshot ? "Your Mac is connected" : "Pair your Mac"
        case .microphone: "Call your Bots"
        default: "Get heads-ups"
        }
    }

    private var subtitle: String {
        switch step {
        case .account: "Use the same account on your iPhone and your Mac."
        case .pair: "Your Bots run on your Mac. This phone sends them messages, end-to-end encrypted."
        case .microphone: "Calls keep going after you leave the app. Mute or hang up from the Dynamic Island."
        default: "Bots tell you when they finish something or need your answer."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .account:
            CloudSignInView(account: account, showsHeading: false)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        case .pair: pairing
        default: EmptyView()
        }
    }

    @ViewBuilder private var pairing: some View {
        if !account.signedIn {
            note("Sign in first, then come back to pair.", icon: "person.crop.circle")
        } else if remote.hasSnapshot {
            note(remote.status, icon: "checkmark.circle.fill")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let phone = account.localDevice {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This phone’s fingerprint").font(.footnote).foregroundStyle(.secondary)
                        Text(phone.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("On your Mac, open Settings → Computer, check it matches, then choose Approve phone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                if account.hosts.isEmpty {
                    note("No Mac yet. Open Grok Bot on your Mac, sign in, and turn on phone access in Settings → Computer.", icon: "desktopcomputer")
                }
                ForEach(account.hosts) { host in
                    Button { remote.select(host) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.system(size: 20)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.name).font(.body.weight(.medium))
                                Text(host.online ? "Online" : "Offline · open Grok Bot on it").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(16).contentShape(Rectangle())
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(!host.online)
                }
                Text(remote.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        switch step {
        case .account:
            if account.signedIn { primary("Continue") { advance() } } else { quiet("I’ll do this later") { advance() } }
        case .pair:
            if remote.hasSnapshot { primary("Continue") { advance() } } else { quiet("I’ll do this later") { advance() } }
        case .microphone:
            primary(asking ? "Waiting…" : "Allow microphone") {
                asking = true
                Task { _ = await VoiceSession.requestAccess(needsSpeech: true); asking = false; advance() }
            }.disabled(asking)
        default:
            primary(asking ? "Waiting…" : "Allow notifications") {
                asking = true
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    asking = false; done()
                }
            }.disabled(asking)
        }
    }

    // MARK: Pieces

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(Palette.background)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color.primary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next } else { done() }
    }

    private func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

/// One character that bobs gently above a step's title.
private struct HeroCharacter: View {
    let shape: String
    let color: String
    @State private var up = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BotGlyphFace(shape: shape, color: color, size: 84)
            .offset(y: up ? -5 : 4)
            .scaleEffect(shown || reduceMotion ? 1 : 0.4)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { shown = true }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

/// Shrinks slightly while pressed, like system buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
