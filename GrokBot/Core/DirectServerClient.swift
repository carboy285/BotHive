import Foundation

/// Talks to a Bothive server by its address (10.1.1), with no account or relay. Sign in once with the server's Web access username and
/// password, then send the same requests the app would send through the account relay: the server answers them in the same shape,
/// so the native Bots list, chat and voice work unchanged against it.
struct DirectServerClient: Codable, Sendable, Equatable {
    var origin: URL
    var token: String
    var name: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private struct Reply: Decodable { var ok: Bool?; var code: String?; var error: String?; var token: String?; var name: String? }

    /// Signs in. Throws an error whose text says what went wrong (wrong password, unreachable, not a Bothive server).
    static func login(address: String, username: String, password: String) async throws -> DirectServerClient {
        let parsed = try ServerAddress.normalize(address)
        guard let origin = URL(string: parsed.origin), let url = URL(string: "/api/app/login", relativeTo: origin)?.absoluteURL else { throw ServerError("That address is not valid.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await send(request, host: parsed.host)
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard let http = response as? HTTPURLResponse else { throw ServerError("\(parsed.host) did not answer like a Bothive server.") }
        switch http.statusCode {
        case 200:
            guard reply?.ok == true, let token = reply?.token else { throw ServerError("\(parsed.host) did not answer like a Bothive server.") }
            return DirectServerClient(origin: origin, token: token, name: reply?.name ?? parsed.host)
        case 401:
            // Only a server that knows this sign-in route says bad_credentials. An older Bothive answers 401 "Sign in again." to a route it does not have.
            if reply?.code == "bad_credentials" { throw ServerError(reply?.error ?? "That username and password don\u{2019}t match.") }
            throw ServerError("\(parsed.host) answered, but it does not accept sign-in from the apps. It is running an older Bothive. Update it to 10.1.1 or later, then try again.")
        case 429: throw ServerError(reply?.error ?? "Too many tries. Wait a minute and try again.")
        case 404: throw ServerError("\(parsed.host) answered, but Web access is not turned on there, or it is not Bothive 10.1.1 or later.")
        default: throw ServerError(reply?.error ?? "\(parsed.host) answered with an error (\(http.statusCode)).")
        }
    }

    private static func send(_ request: URLRequest, host: String) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ServerError("Could not reach \(host). Check the address, that Bothive is running there with Web access on, and that Tailscale is on if you use it.") }
    }

    /// Sends one relay-style request and returns the host's answer.
    func fetch(target: String, command: RemoteCommand? = nil) async throws -> CloudResponse {
        try Task.checkCancellation()
        guard let url = URL(string: "/api/app/request", relativeTo: origin)?.absoluteURL else { throw ServerError("That address is not valid.") }
        let relay = CloudRequest(method: command == nil ? "GET" : "POST", target: target, body: try command.map { try CloudCoding.encoder().encode($0) } ?? Data())
        var request = URLRequest(url: url, timeoutInterval: command == nil ? 15 : 40)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try CloudCoding.encoder().encode(relay)
        let (data, response) = try await Self.send(request, host: origin.host ?? "the server")
        guard let http = response as? HTTPURLResponse else { throw ServerError("The server did not answer.") }
        if http.statusCode == 401 { throw CloudError.signedOut }
        if http.statusCode == 429 || http.statusCode == 409 || http.statusCode == 400 || http.statusCode == 413 {
            throw ServerError((try? JSONDecoder().decode(Reply.self, from: data))?.error ?? "The server could not complete this request.")
        }
        guard http.statusCode == 200 else { throw ServerError("The server answered with an error (\(http.statusCode)).") }
        return try CloudCoding.decoder().decode(CloudResponse.self, from: data)
    }

    /// A stand-in for the "computer" the rest of the app talks about, so the existing screens can show this server as one.
    var device: CloudDevice {
        let digest = Data((origin.absoluteString).utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in digest.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return CloudDevice(id: id, name: name, kind: "host", public_key: "", last_seen: Date(), available: true)
    }
}
