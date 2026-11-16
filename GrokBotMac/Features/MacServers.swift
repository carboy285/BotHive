import AppKit
import SwiftUI

/// Settings → Servers (10.1.1): use a Bothive that runs somewhere else by its address (Tailscale, home network or https).
/// Sign in once with the server's Web access username and password, and its Bots load in this window like this Mac's own.
struct MacServersSettings: View {
    @EnvironmentObject private var desktop: MacAppModel
    @EnvironmentObject private var app: AppModel
    var body: some View { MacServersPage(list: desktop.servers) }
}

private struct MacServersPage: View {
    @ObservedObject var list: ServerList
    @EnvironmentObject private var desktop: MacAppModel
    @EnvironmentObject private var app: AppModel
    @State private var address = ""
    @State private var name = ""
    @State private var message: String?
    @State private var toRemove: SavedServer?
    @State private var signingIn: SavedServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Use a Bothive that runs on another computer, a home server or a Docker container, instead of this Mac. Add its address, sign in with the username and password from its Web access settings, and its Bots load in this window. You chat and talk to them here. Chats and Bots stay on that server.")
                .font(.system(size: 14)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if let gateway = desktop.gateway, gateway.remote.usingServer {
                InspectorCard(title: "Connected") {
                    Text("Using \(gateway.hostName)").font(.system(size: 14, weight: .semibold))
                    Button("Back to this Mac") { desktop.openComputer(nil, app: desktop.localApp ?? app) }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
                }
            }
            InspectorCard(title: "Your servers") {
                if list.servers.isEmpty { Text("No servers yet. Add one below.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
                ForEach(list.servers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.system(size: 14, weight: .semibold))
                        Text(server.url).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Button("Connect") { signingIn = server }.buttonStyle(InspectorButtonStyle(tint: .accentColor, compact: true))
                            Button("Remove", role: .destructive) { toRemove = server }.buttonStyle(InspectorButtonStyle(destructive: true, compact: true))
                        }
                    }
                    Divider()
                }
            }
            InspectorCard(title: "Add a server", footer: "With Tailscale, turn it on here and on the server, then use the server\u{2019}s Tailscale address. Plain http:// is only for private addresses (Tailscale 100.x, home Wi-Fi). Anything else needs https://.") {
                TextField("https://my-box.tailnet-name.ts.net  \u{00B7}  http://100.101.102.103:8765", text: $address).textFieldStyle(.roundedBorder).onSubmit(add)
                TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
                Button("Add server", action: add).buttonStyle(InspectorButtonStyle(tint: .accentColor)).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
        }
        .sheet(item: $signingIn) { server in MacServerSignIn(server: server) }
        .confirmationDialog("Remove this server?", isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }), presenting: toRemove) { server in
            Button("Remove \u{201C}\(server.name)\u{201D}", role: .destructive) { list.remove(server); message = "Server removed." }
        }
    }

    private func add() {
        do {
            let entry = try list.add(name: name, address: address)
            message = "Added \u{201C}\(entry.name)\u{201D}. Press Connect to sign in."
            address = ""; name = ""
        } catch { message = error.localizedDescription }
    }
}

private struct MacServerSignIn: View {
    let server: SavedServer
    @EnvironmentObject private var desktop: MacAppModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = "admin"
    @State private var password = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(server.name)").font(.system(size: 18, weight: .medium))
            Text("This is the username and password from Settings \u{2192} Web access on that server. It is checked there and never stored on this Mac.")
                .font(.system(size: 12)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Username", text: $username).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(signIn)
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Signing in\u{2026}" : "Sign in", action: signIn).keyboardShortcut(.defaultAction).disabled(working || username.isEmpty || password.isEmpty)
            }
        }.padding(22).frame(width: 380)
    }

    private func signIn() {
        guard !working, !username.isEmpty, !password.isEmpty else { return }
        working = true; message = nil
        let secret = password; password = ""
        Task {
            do {
                let client = try await DirectServerClient.login(address: server.url, username: username, password: secret)
                desktop.openServer(client, app: desktop.localApp ?? app)
                dismiss()
            } catch { message = error.localizedDescription; working = false }
        }
    }
}
