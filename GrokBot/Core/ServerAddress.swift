import Foundation

// Servers (10.1.1): use a Bothive that runs somewhere else (a home server, a Docker container, another computer) by its address,
// for example https://my-box.tailnet-name.ts.net or http://100.101.102.103:8765. You sign in once with the server's Web access
// username and password, and its Bots then load in the app itself. Same address rules as desktop-windows/app/servers.cjs.

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

/// The servers this device has saved. Stored in the app's preferences (addresses only; the password is never kept).
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

    /// Forgets the address. (A sign-in this device kept for the server being used now is ended by RemoteController.leaveServer.)
    func remove(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        save()
    }
}
