import SwiftUI
import WebKit

/// Servers (10.1.1): use a Bothive that runs somewhere else by its address (Tailscale, home network or https).
/// The server opens full screen and you sign in on its own page. Chats and Bots stay on that server.
struct ServersPage: View {
    @StateObject private var list = ServerList()
    @State private var address = ""
    @State private var name = ""
    @State private var message: String?
    @State private var opened: SavedServer?

    var body: some View {
        List {
            Section {
                Text("Use a Bothive that runs on a computer, a home server or a Docker container, instead of connecting through your account. Type its address, open it, and sign in with the username and password from its Web access settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Your servers") {
                if list.servers.isEmpty { Text("No servers yet. Add one below.").foregroundStyle(.secondary) }
                ForEach(list.servers) { server in
                    Button { opened = server } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.body).foregroundStyle(.primary)
                            Text(server.url).font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .swipeActions { Button("Remove", role: .destructive) { list.remove(server) } }
                    .accessibilityHint("Opens this server")
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
        .fullScreenCover(item: $opened) { server in ServerWebScreen(server: server) }
    }

    private func add() {
        do {
            let entry = try list.add(name: name, address: address)
            message = "Added \u{201C}\(entry.name)\u{201D}."
            address = ""; name = ""
        } catch { message = error.localizedDescription }
    }
}

private struct ServerWebScreen: View {
    let server: SavedServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = URL(string: server.url) { ServerWebView(origin: url).ignoresSafeArea(edges: .bottom) }
                else { ContentUnavailableView("Address not valid", systemImage: "exclamationmark.triangle") }
            }
            .navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ServerWebView: UIViewRepresentable {
    let origin: URL
    func makeCoordinator() -> ServerWebDelegate { ServerWebDelegate(origin: origin) }
    func makeUIView(context: Context) -> WKWebView { ServerWebDelegate.makeWebView(origin: origin, delegate: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
