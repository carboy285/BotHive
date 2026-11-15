import AppKit
import SwiftUI

struct MacSetupView: View {
    @EnvironmentObject private var desktop: MacAppModel
    @State private var step = 0
    @State private var provider = CLIProvider.codex
    /// First run opens on the Bots saying hello (0.9.9). Opening setup again from Settings goes straight to the steps.
    @State private var greeting = !UserDefaults.standard.bool(forKey: "localCLISetupComplete")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var installation: InstalledCLI? { desktop.installedCLIs.first { $0.provider == provider } }

    /// One character per step, so each screen has its own face.
    private static let faces: [(shape: String, color: String)] = [
        ("cloud", "green"), ("square", "blue"), ("hexagon", "orange"), ("droplet", "purple"), ("flower", "teal"), ("heart", "red"),
    ]

    var body: some View {
        ZStack {
            if greeting {
                hello.transition(.opacity)
            } else {
                steps.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.9), value: greeting)
        .onAppear { desktop.refreshCLIs(); if let requested = desktop.setupProvider { provider = requested; desktop.setupProvider = nil } else if let current = desktop.selectedCLI { provider = current.provider } }
        .onChange(of: provider) { _, _ in desktop.loginVerified = false; desktop.setupFeedback = nil; if let installation { desktop.chooseCLI(installation.id) } }
        .onChange(of: desktop.installedCLIs) { _, _ in if let installation { desktop.chooseCLI(installation.id) } }
    }

    /// The first thing a new Mac user sees: the Bots floating around the name.
    private var hello: some View {
        ZStack {
            CharacterCrowd(sizeFactor: 0.13)
            VStack(spacing: 12) {
                Text("Grok Bot").font(.system(size: 44, weight: .semibold)).tracking(-1)
                Text("Bots that keep working on your Mac,\nwith the AI CLI you already use.")
                    .font(.system(size: 17)).foregroundStyle(MacTheme.secondary).multilineTextAlignment(.center).lineSpacing(3)
                MacPillButton(title: "Get started", prominent: true) { greeting = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { desktop.panel = nil } label: { Image(systemName: "xmark").frame(width: 34, height: 34) }
                        .buttonStyle(.plain).accessibilityLabel("Close setup")
                }
                Spacer()
                Button("Finish later") { desktop.panel = nil }.buttonStyle(.link).foregroundStyle(MacTheme.secondary)
            }
            .padding(24)
        }
    }

    private var steps: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                BotGlyphFace(shape: "circle", color: "white", size: 24)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1).padding(1))
                Text("Set up Grok Bot").font(.system(size: 15, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<6) { index in
                        Capsule().fill(index <= step ? Color.primary : MacTheme.raised)
                            .frame(width: index == step ? 22 : 7, height: 7)
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: step)
                .accessibilityElement().accessibilityLabel("Step \(step + 1) of 6")
                Spacer()
                Button { desktop.panel = nil } label: { Image(systemName: "xmark").frame(width: 34, height: 34) }.buttonStyle(.plain).accessibilityLabel("Close setup")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StepCharacter(shape: Self.faces[step].shape, color: Self.faces[step].color).id(step)
                    switch step {
                    case 0: welcome
                    case 1: choose
                    case 2: install
                    case 3: signIn
                    case 4: MacComposioSetupView(service: desktop.composio)
                    default: ready
                    }
                }.frame(maxWidth: 620, alignment: .leading).padding(.vertical, 16).frame(maxWidth: .infinity)
            }
            HStack(spacing: 15) {
                if step > 0 { MacPillButton(title: "Back") { step -= 1 } }
                else { Button("Finish later") { desktop.panel = nil }.buttonStyle(.link) }
                Spacer()
                if step < 5 {
                    MacPillButton(title: step == 4 ? "Continue to chat" : "Continue", prominent: true) {
                        if let installation { desktop.chooseCLI(installation.id) }
                        step += 1
                    }.disabled((step == 2 && installation == nil) || (step == 3 && (!desktop.loginVerified || installation == nil)))
                } else {
                    MacPillButton(title: "Start chatting", prominent: true) { desktop.completeSetup() }.disabled(installation == nil)
                }
            }
        }
        .padding(32)
    }

    private var welcome: some View {
        Group {
            title("A free app for your AI CLIs")
            lead("Grok Bot talks to an AI CLI already on this Mac. Pick one, sign in through it, and send your first message.")
            info("Free and open source", "Your CLI's account or your local model pays for the AI. This app adds no subscription, and free AI access isn't guaranteed.", icon: "heart")
            info("Your setup stays yours", "The CLI keeps its own login and model settings. You never paste secrets into this app.", icon: "terminal")
        }
    }

    private var choose: some View {
        Group {
            title("Choose an AI CLI")
            lead("These are the CLIs on this Mac. You can switch later; each one keeps its own conversations.")
            ForEach(CLIProvider.allCases) { candidate in
                let found = desktop.installedCLIs.first { $0.provider == candidate }
                if let health = desktop.providerHealth[candidate] { Text("\(candidate.name): \(health)").font(.caption).foregroundStyle(.secondary) }
                Button { provider = candidate } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "terminal").font(.system(size: 21)).frame(width: 31)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.name).font(.system(size: 17, weight: .medium))
                            Text(found?.version ?? "Not installed").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                        }
                        Spacer()
                        Image(systemName: provider == candidate ? "checkmark.circle.fill" : "circle").font(.system(size: 19))
                    }
                    .padding(15).contentShape(Rectangle())
                    .background(provider == candidate ? MacTheme.raised : MacTheme.canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(provider == candidate ? Color.primary.opacity(0.35) : MacTheme.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            HStack {
                Button(desktop.scanningCLIs ? "Scanning…" : "Scan again") { desktop.refreshCLIs() }.disabled(desktop.scanningCLIs)
                Spacer()
                Button("Choose executable…") { chooseExecutable() }
            }
        }
    }

    private var install: some View {
        Group {
            title("Install \(provider.name)")
            if let installation {
                Label("Already installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(installation.path).font(.system(size: 13, design: .monospaced)).lineLimit(2).truncationMode(.middle).help(installation.path).textSelection(.enabled)
                Text("You can continue to sign in. If this is not the installation you want, choose another executable.").foregroundStyle(MacTheme.secondary)
            } else {
                lead("Install the CLI, then come back and scan again. Grok Bot never installs anything in the background.")
                if provider != .grok {
                    Text("If you use npm, install Node.js first, then run:").foregroundStyle(MacTheme.secondary)
                    command(provider.installCommand)
                    if CLISignIn.canInstall(provider) { MacPillButton(title: "Install in Terminal") { try? CLISignIn.openInTerminal(provider.installCommand, title: provider.name) } }
                    Link("Get Node.js ↗", destination: URL(string: "https://nodejs.org/en/download")!)
                }
            }
            HStack {
                Link("Official install guide ↗", destination: provider.guideURL)
                Spacer()
                MacPillButton(title: desktop.scanningCLIs ? "Scanning…" : "Scan again") { desktop.refreshCLIs() }.disabled(desktop.scanningCLIs)
            }
            Button("Choose executable…") { chooseExecutable() }.buttonStyle(.link)
            info("Only a real CLI answers", "Nothing is bundled or simulated. The CLI's account decides which models you get and what they cost.", icon: "checkmark.shield")
        }
    }

    private var signIn: some View {
        Group {
            title("Sign in through \(provider.name)")
            lead("Run this in Terminal, finish the CLI’s login, then come back.")
            command(provider.loginCommand)
            MacPillButton(title: "Sign in in Terminal") { try? CLISignIn.openInTerminal(provider.loginCommand, title: provider.name) }.disabled(installation == nil)
            Text(CLISignIn.credentialLabel(for: provider)).font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
            HStack {
                MacPillButton(title: "Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                MacPillButton(title: desktop.checkingLogin ? "Checking…" : (provider == .codex ? "Check sign-in" : "I’ve configured this CLI"), prominent: true) {
                    if let installation { desktop.chooseCLI(installation.id) }
                    desktop.checkLogin()
                }.disabled(desktop.checkingLogin || installation == nil)
            }
            if let feedback = desktop.setupFeedback { Text(feedback).foregroundStyle(MacTheme.secondary).lineSpacing(5) }
            info("Your login stays with the CLI", "Grok Bot never copies your token. Codex sign-in is checked here; other CLIs are checked when you send your first message.", icon: "lock")
        }
    }

    private var ready: some View {
        Group {
            title("Ready for your first message")
            lead("Grok Bot starts with an empty chat. Add more Bots whenever you like; each keeps its own session with the CLI.")
            if let installation { Label("\(installation.provider.name) on this Mac", systemImage: "terminal").font(.headline) }
            info("Use your iPhone", "In Settings → Computer, sign in and turn on phone access. Sign in on your iPhone with the same account, check the fingerprint, and approve it here.", icon: "iphone")
            info("You stay in control", "No approval-bypass flags. Codex gets read-only workspace access, other CLIs keep their own permissions, and you can stop any reply.", icon: "hand.raised")
        }
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }.padding(17).background(MacTheme.raised, in: RoundedRectangle(cornerRadius: 13))
    }
    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 30, weight: .semibold)).tracking(-0.6)
    }
    private func lead(_ text: String) -> some View {
        Text(text).font(.system(size: 17)).lineSpacing(5).foregroundStyle(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
    }
    private func info(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34)
                .background(MacTheme.raised, in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(detail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MacTheme.line, lineWidth: 1))
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the \(provider.name) CLI executable installed on this Mac."
        if panel.runModal() == .OK, let url = panel.url { desktop.setCLIPath(url.path, provider: provider) }
    }
}

/// The character at the top of a setup step. It pops in when the step changes and bobs slowly.
private struct StepCharacter: View {
    let shape: String
    let color: String
    @State private var shown = false
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BotGlyphFace(shape: shape, color: color, size: 64)
            .offset(y: up ? -3 : 3)
            .scaleEffect(shown || reduceMotion ? 1 : 0.5)
            .opacity(shown || reduceMotion ? 1 : 0)
            .padding(.bottom, 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { shown = true }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { up = true }
            }
    }
}
