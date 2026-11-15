import AppKit
import SwiftUI

/// The account menu (10.1): press the round account button at the bottom of the sidebar and a small menu opens above it.
/// Who is signed in, get the iPhone app, support links, Settings, and signing in or out.
struct MacAccountMenu: View {
    @EnvironmentObject private var desktop: MacAppModel
    let dismiss: () -> Void
    var body: some View { MacAccountMenuContent(account: desktop.remote.account, dismiss: dismiss) }
}

private struct MacAccountMenuContent: View {
    @ObservedObject var account: CloudAccount
    @EnvironmentObject private var desktop: MacAppModel
    let dismiss: () -> Void
    private static let site = "https://carboy285.github.io/BotHive/"
    private static let issues = "https://github.com/carboy285/BotHive/issues"

    private func open(_ address: String) {
        dismiss()
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.signedIn ? account.email : "Not signed in")
                .font(.system(size: 13)).foregroundStyle(MacTheme.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            Divider().padding(.horizontal, 8).padding(.bottom, 4)
            Button { open(Self.site + "iphone.html") } label: { rowLabel("Get Bothive for iPhone", symbol: "iphone") }.buttonStyle(AccountRowStyle())
            Menu {
                Button("Report a problem") { open(Self.issues) }
                Button("Privacy") { open(Self.site + "privacy.html") }
                Button("Terms") { open(Self.site + "terms.html") }
                Button("Licenses") { open(Self.site + "licenses.html") }
                Button("Website") { open(Self.site) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle").font(.system(size: 15)).foregroundStyle(MacTheme.secondary).frame(width: 20)
                    Text("Support").font(.system(size: 15))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MacTheme.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            Button { dismiss(); desktop.openSettings() } label: { rowLabel("Settings", symbol: "gearshape") }.buttonStyle(AccountRowStyle())
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            if account.signedIn {
                Button { dismiss(); Task { await account.signOut() } } label: { rowLabel("Sign out", symbol: "rectangle.portrait.and.arrow.right") }.buttonStyle(AccountRowStyle())
            } else {
                Button { dismiss(); desktop.openSettings(.computer) } label: { rowLabel("Sign in", symbol: "person.crop.circle") }.buttonStyle(AccountRowStyle())
            }
        }.padding(8).frame(width: 270)
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(MacTheme.secondary).frame(width: 20)
            Text(title).font(.system(size: 15))
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
    }
}

private struct AccountRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
