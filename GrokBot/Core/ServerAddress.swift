import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Servers (10.1.1): use a Bothive that runs somewhere else (a home server, a Docker container, another computer) by its address,
// for example https://my-box.tailnet-name.ts.net or http://100.101.102.103:8765. The app opens that address in its own web view
// and you sign in on the server's page. Same rules as desktop-windows/app/servers.cjs.

struct SavedServer: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var url: String
}

struct ServerError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ServerAddress {
    static let maxServers = 20

    struct Parsed: Equatable, Sendable {
        var origin: String
        var host: String
        var https: Bool
    }

    /// Plain http is only for networks that are private by nature: home Wi-Fi, Tailscale and local names.
    static func isPrivate(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") { host.removeFirst() }
        if host.hasSuffix("]") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") || host == "::1" { return true }
        if host.contains(":") { return ["fc", "fd", "fe80"].contains { host.hasPrefix($0) } }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) {
            let n = parts.compactMap(Int.init)
            guard n.count == 4, n.allSatisfy({ $0 <= 255 }) else { return false }
            return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1]))
                || (n[0] == 169 && n[1] == 254) || (n[0] == 100 && (64...127).contains(n[1]))
        }
        // A short name with no dots, such as a Tailscale MagicDNS name.
        return !host.isEmpty && !host.contains(".") && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Turns what a person typed into an origin, or throws an error that says what to fix.
    static func normalize(_ input: String) throws -> Parsed {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServerError("Type the server\u{2019}s address, for example https://my-box.tailnet-name.ts.net.") }
        guard text.count <= 300 else { throw ServerError("That address is too long.") }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil {
            let host = text.split(whereSeparator: { "/:?#".contains($0) }).first.map(String.init) ?? text
            text = (isPrivate(host) ? "http://" : "https://") + text
        }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased() else { throw ServerError("That address is not valid.") }
        guard scheme == "http" || scheme == "https" else { throw ServerError("Use an address that starts with https:// or http://.") }
        guard parts.user == nil, parts.password == nil else { throw ServerError("Leave the username and password out of the address. You sign in on the server\u{2019}s own page.") }
        guard (parts.path.isEmpty || parts.path == "/"), parts.query == nil, parts.fragment == nil else { throw ServerError("Use just the address, with no page after it.") }
        guard let host = parts.host?.lowercased(), !host.isEmpty else { throw ServerError("That address has no server name.") }
        if scheme == "http", !isPrivate(host) { throw ServerError("Plain http is only for private addresses (Tailscale, home Wi-Fi). For anything else use https://.") }
        let shown = host.contains(":") ? "[" + host + "]" : host
        var origin = scheme + "://" + shown
        if let port = parts.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) { origin += ":\(port)" }
        let hostWithPort = origin.dropFirst(scheme.count + 3)
        return Parsed(origin: origin, host: String(hostWithPort), https: scheme == "https")
    }

    static func cleanName(_ name: String, fallback: String) -> String {
        let scrubbed = BotSkills.scrub(name).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let short = String(scrubbed.prefix(60))
        return short.isEmpty ? fallback : short
    }

    /// Keeps only valid saved entries, at most `maxServers`.
    static func clean(_ servers: [SavedServer]) -> [SavedServer] {
        Array(servers.filter { server in
            !server.name.trimmingCharacters(in: .whitespaces).isEmpty && server.name.count <= 60 && ((try? normalize(server.url))?.origin == server.url)
        }.prefix(maxServers))
    }
}

/// The servers this device has saved. Stored in the app's preferences (addresses only: signing in happens on the server's page).
@MainActor
final class ServerList: ObservableObject {
    @Published private(set) var servers: [SavedServer] = []
    private let key: String

    init(key: String = "savedServers") {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([SavedServer].self, from: data) { servers = ServerAddress.clean(list) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: key) }
    }

    @discardableResult
    func add(name: String, address: String) throws -> SavedServer {
        let parsed = try ServerAddress.normalize(address)
        guard servers.count < ServerAddress.maxServers else { throw ServerError("You have the most servers this app keeps (\(ServerAddress.maxServers)). Remove one first.") }
        guard !servers.contains(where: { $0.url == parsed.origin }) else { throw ServerError("That server is already in your list.") }
        let entry = SavedServer(name: ServerAddress.cleanName(name, fallback: parsed.host), url: parsed.origin)
        servers.append(entry)
        save()
        return entry
    }

    /// Forgets the server and the sign-in this device kept for it.
    func remove(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        save()
        guard let host = URL(string: server.url)?.host else { return }
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { $0.displayName == host || host.hasSuffix("." + $0.displayName) || $0.displayName.hasSuffix(host) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {}
        }
    }
}

/// Keeps a server's web view on that server: links to other sites open in the browser, new windows are refused,
/// the camera and microphone are denied, and a failed load says so instead of showing a blank page.
@MainActor
final class ServerWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let origin: URL

    init(origin: URL) { self.origin = origin }

    /// A web view for the server at `origin`, already pointed at it.
    static func makeWebView(origin: URL, delegate: ServerWebDelegate) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: origin, timeoutInterval: 20))
        return view
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased() && url.host?.lowercased() == origin.host?.lowercased() && url.port == origin.port
    }

    private func openOutside(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        if scheme == "about" || scheme == "data" || sameOrigin(url) { return .allow }
        openOutside(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openOutside(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showFailure(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showFailure(webView, error) }

    private func showFailure(_ webView: WKWebView, _ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let host = (origin.host ?? "the server").filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }
        let page = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><body style=\"font:16px -apple-system,system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0\"><div style=\"max-width:420px;padding:24px;text-align:center\"><h2>Could not reach \(host)</h2><p style=\"color:#aaa\">Check that Bothive is running there with Web access on, and that Tailscale is on if you use it. Close this and open the server again to retry.</p></div>"
        webView.loadHTMLString(page, baseURL: nil)
    }
}
