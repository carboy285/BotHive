import SwiftUI

/// Servers (10.1.1): use a Bothive that runs somewhere else by its address (Tailscale, home network or https).
/// Sign in once with the server's Web access username and password, and its Bots load in this app. You text and talk to them here.
/// Chats and Bots stay on that server.
struct ServersPage: View {
    @EnvironmentObject private var remote: RemoteController
    @StateObject private var list = ServerList()
    @State private var address = ""
    @State private var name = ""
    @State private var message: String?
    @State private var signingIn: SavedServer?

    var body: some View {
        List {
            Section {
                Text("Use a Bothive that runs on a computer, a home server or a Docker container, instead of connecting through your account. Add its address, sign in with the username and password from its Web access settings, and its Bots load here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let current = remote.serverName {
                Section {
                    Text("Using \(current)").font(.body.weight(.medium))
                    Button("Back to my account\u{2019}s computer", role: .destructive) { remote.leaveServer() }
                }
            }
            Section("Your servers") {
                if list.servers.isEmpty { Text("No servers yet. Add one below.").foregroundStyle(.secondary) }
                ForEach(list.servers) { server in
                    Button { signingIn = server } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.body).foregroundStyle(.primary)
                            Text(server.url).font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .swipeActions { Button("Remove", role: .destructive) { list.remove(server) } }
                    .accessibilityHint("Signs in to this server")
                }
            }
            Section(header: Text("Add a server"), footer: Text("With Tailscale, turn it on here and on the server, then use the server\u{2019}s Tailscale address. Plain http:// is only for private addresses (Tailscale 100.x, home Wi-Fi). Anything else needs https://.")) {
                TextField("https://my-box.tailnet-name.ts.net", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Server address")
                TextField("Name (optional)", text: $name)
                Button("Add server") { add() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Servers").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $signingIn) { server in ServerSignIn(server: server) }
    }

    private func add() {
        do {
            let entry = try list.add(name: name, address: address)
            message = "Added \u{201C}\(entry.name)\u{201D}. Tap it to sign in."
            address = ""; name = ""
        } catch { message = error.localizedDescription }
    }
}

private struct ServerSignIn: View {
    let server: SavedServer
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var username = "admin"
    @State private var password = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("This is the username and password from Settings \u{2192} Web access on \(server.name). It is checked by that server and never stored on this iPhone.")) {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button { signIn() } label: { if working { ProgressView() } else { Text("Sign in") } }
                        .disabled(working || username.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func signIn() {
        working = true; message = nil
        let secret = password; password = ""
        Task {
            do {
                let client = try await DirectServerClient.login(address: server.url, username: username, password: secret)
                remote.connectServer(client)
                dismiss()
            } catch { message = error.localizedDescription; working = false }
        }
    }
}
