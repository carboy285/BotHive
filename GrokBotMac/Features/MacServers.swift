import AppKit
import SwiftUI
import WebKit

/// Opens a Bothive that runs somewhere else (10.1.1) in its own window. The window shows the server's own page; you sign in there.
@MainActor
final class MacServerWindows {
    static let shared = MacServerWindows()
    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: ServerWebDelegate] = [:]

    func open(_ server: SavedServer) {
        if let existing = windows[server.id] { existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let url = URL(string: server.url) else { return }
        let delegate = ServerWebDelegate(origin: url)
        let view = ServerWebDelegate.makeWebView(origin: url, delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bothive \u{00B7} " + server.name
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        let id = server.id
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows[id] = nil; self?.delegates[id] = nil }
        }
        windows[id] = window
        delegates[id] = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ server: SavedServer) { windows[server.id]?.close() }
}

/// Settings → Servers: addresses of other Bothive servers (Tailscale, home network or https) to open instead of this Mac.
struct MacServersSettings: View {
    @EnvironmentObject private var desktop: MacAppModel
    var body: some View { MacServersPage(list: desktop.servers) }
}

private struct MacServersPage: View {
    @ObservedObject var list: ServerList
    @State private var address = ""
    @State private var name = ""
    @State private var message: String?
    @State private var toRemove: SavedServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Use a Bothive that runs on another computer, a home server or a Docker container, instead of this Mac. Type its address, open it, and sign in with the username and password from its Web access settings. Chats and Bots stay on that server.")
                .font(.system(size: 14)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            InspectorCard(title: "Your servers") {
                if list.servers.isEmpty { Text("No servers yet. Add one below.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
                ForEach(list.servers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.system(size: 14, weight: .semibold))
                        Text(server.url).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Button("Open") { MacServerWindows.shared.open(server) }.buttonStyle(InspectorButtonStyle(tint: .accentColor, compact: true))
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
        .confirmationDialog("Remove this server?", isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }), presenting: toRemove) { server in
            Button("Remove \u{201C}\(server.name)\u{201D}", role: .destructive) {
                MacServerWindows.shared.close(server)
                list.remove(server)
                message = "Server removed."
            }
        } message: { _ in Text("You will have to sign in again if you add it back.") }
    }

    private func add() {
        do {
            let entry = try list.add(name: name, address: address)
            message = "Added \u{201C}\(entry.name)\u{201D}."
            address = ""; name = ""
        } catch { message = error.localizedDescription }
    }
}
