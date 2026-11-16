import SwiftUI

/// iPhone settings (10.0): a gray page with a round close button, white rounded cards of rows, small section labels,
/// a red Sign out card and the app's name and version at the bottom. Rows are plain buttons, so everything wraps and
/// scrolls at the largest text sizes.
struct SettingsView: View {
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("appearance") private var appearance = "system"
    @State private var disconnect = false
    @State private var signOut = false
    @State private var voice = false

    private var account: CloudAccount { remote.account }
    private var appearanceName: String { appearance == "dark" ? "Dark" : appearance == "light" ? "Light" : "System" }
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—", build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SettingsCard {
                        NavigationLink { AccountPage() } label: {
                            SettingsRow(title: account.signedIn ? account.email : "Sign in",
                                        subtitle: account.signedIn ? "Your Bothive account" : "Use the same account as your computer",
                                        leading: AnyView(Initials(text: account.signedIn ? account.email : "")))
                        }.buttonStyle(SettingsRowStyle())
                    }

                    SettingsCard(label: "Your computer", footer: remote.hasSnapshot ? "Disconnecting this phone leaves your Bots, chats and running work on the computer." : nil) {
                        Button { dismiss(); Task { try? await Task.sleep(for: .milliseconds(500)); remote.showConnection = true } } label: {
                            SettingsRow(title: remote.hasSnapshot ? remote.hostName : "Connect your computer", subtitle: remote.status)
                        }.buttonStyle(SettingsRowStyle())
                        if remote.hasSnapshot {
                            SettingsDivider()
                            Button { disconnect = true } label: { SettingsRow(title: "Disconnect this iPhone", accessory: .none, tint: .red) }
                                .buttonStyle(SettingsRowStyle())
                        }
                        SettingsDivider()
                        NavigationLink { ServersPage() } label: { SettingsRow(title: "Servers", subtitle: "Use a Bothive by its Tailscale or IP address") }.buttonStyle(SettingsRowStyle())
                        SettingsDivider()
                        NavigationLink { IntegrationView() } label: { SettingsRow(title: "Set-up guide") }.buttonStyle(SettingsRowStyle())
                    }

                    SettingsCard(label: "App") {
                        Button { voice = true } label: { SettingsRow(title: "Voice", subtitle: "Listening, speaking and patience") }.buttonStyle(SettingsRowStyle())
                        SettingsDivider()
                        NavigationLink { AppearancePage() } label: { SettingsRow(title: "Appearance", value: appearanceName) }.buttonStyle(SettingsRowStyle())
                    }

                    SettingsCard(footer: LegalLinks.aiNotice + " " + LegalLinks.affiliation) {
                        link("Website", LegalLinks.site); SettingsDivider()
                        link("Privacy policy", LegalLinks.privacy); SettingsDivider()
                        link("Terms", LegalLinks.terms); SettingsDivider()
                        link("Open-source licenses", LegalLinks.licenses); SettingsDivider()
                        link("Report a problem", LegalLinks.issues)
                    }

                    if account.signedIn {
                        SettingsCard {
                            Button { signOut = true } label: { SettingsRow(title: "Sign out", accessory: .none, tint: .red) }.buttonStyle(SettingsRowStyle())
                        }
                    }

                    VStack(spacing: 6) {
                        BotAvatar(size: 44).padding(.bottom, 6)
                        Text("Bothive").font(.headline)
                        Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                        Text("Bots run on your Mac or Windows PC, using its accounts and permissions.")
                            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)
                    .accessibilityElement(children: .combine)
                }
                .padding(.horizontal, 16).padding(.top, 68)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(SettingsTheme.background)
            .overlay(alignment: .top) { header }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $voice) { VoiceSettingsView() }
            .confirmationDialog("Disconnect this phone from your computer?", isPresented: $disconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { remote.disconnect() }
            }
            .confirmationDialog("Sign out of Bothive on this iPhone?", isPresented: $signOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
            }
        }
    }

    /// The round close button. Rows scroll under a fade, so the button never sits on top of text.
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 40, height: 40).background(SettingsTheme.card, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close settings")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 22)
        .background {
            LinearGradient(stops: [.init(color: SettingsTheme.background, location: 0), .init(color: SettingsTheme.background, location: 0.6),
                                   .init(color: SettingsTheme.background.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button { openURL(url) } label: { SettingsRow(title: title, accessory: .external) }.buttonStyle(SettingsRowStyle())
    }
}

/// Sign in, create an account, sign out and delete the account.
private struct AccountPage: View {
    @EnvironmentObject private var remote: RemoteController
    var body: some View {
        ScrollView {
            CloudSignInView(account: remote.account)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.radius, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(SettingsTheme.background)
        .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearancePage: View {
    @AppStorage("appearance") private var appearance = "system"
    private let options = [("system", "Follow system"), ("light", "Light"), ("dark", "Dark")]
    var body: some View {
        ScrollView {
            SettingsCard(footer: "Follow system switches between light and dark with your iPhone.") {
                ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
                    if index > 0 { SettingsDivider() }
                    Button { appearance = option.0 } label: {
                        HStack {
                            Text(option.1).font(.body).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if appearance == option.0 { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowStyle())
                    .accessibilityAddTraits(appearance == option.0 ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(SettingsTheme.background)
        .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Pieces

private enum SettingsTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let radius: CGFloat = 20
}

/// A white rounded card, with an optional small label above it and a footnote below.
private struct SettingsCard<Content: View>: View {
    var label: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.radius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: SettingsTheme.radius, style: .continuous))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

private struct SettingsRow: View {
    enum Accessory { case none, chevron, external }
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var accessory: Accessory = .chevron
    var tint: Color = .primary
    var leading: AnyView? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(tint).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            switch accessory {
            case .none: EmptyView()
            case .chevron: Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            case .external: Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13).frame(minHeight: 52, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Rows dim while pressed, like a system list.
private struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.07 : 0))
    }
}

private struct Initials: View {
    let text: String
    var body: some View {
        Group {
            if text.isEmpty { Image(systemName: "person.crop.circle").font(.system(size: 30)).foregroundStyle(.secondary) }
            else { Text(String(text.filter(\.isLetter).prefix(2)).uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 36, height: 36).background(Color.primary.opacity(0.08), in: Circle()) }
        }.accessibilityHidden(true)
    }
}

struct IntegrationView: View {
    var body: some View {
        Form {
            Section("1 · Desktop setup") { Text("Choose and sign into an AI CLI on your Mac. Optional Composio tools also run there.") }
            Section("2 · One account") { Text("In Mac Settings → Computer, create an email account, confirm the email, and sign in. Turn on Allow phone access. Sign into the same account on this iPhone.") }
            Section("3 · Approve this phone") { Text("Compare the phone’s fingerprint on both screens. Click Approve phone on your Mac, then choose your Mac in Connect Desktop on the phone.") }
            Section("Anywhere you go") { Text("The apps connect through Supabase over HTTPS, with encrypted commands and replies. Keep the Mac awake and the desktop app running. No VPN, pairing link, public IP, or router setup is needed.") }
        }.navigationTitle("Desktop setup").navigationBarTitleDisplayMode(.inline)
    }
}
