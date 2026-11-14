import Foundation

/// A counter that waiters can sleep on (0.9.9). Read `count` before you poll, then `wait(after:upTo:)`: it returns
/// as soon as the count moves past what you read, so a ping that lands mid-poll is never missed.
@MainActor
final class CloudPulse {
    private(set) var count = 0
    func signal() { count &+= 1 }
    /// Returns true when signalled, false when `limit` passes first.
    @discardableResult
    func wait(after seen: Int, upTo limit: Duration) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now + limit
        while count == seen {
            if clock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: min(.milliseconds(15), deadline - clock.now))
        }
        return true
    }
}

/// "You have mail" over Supabase Realtime (0.9.9). The relay's database pings `opengrok:<device id>` on a private
/// Broadcast channel whenever a packet is stored for this device (supabase/migrations/20261114200000_relay_wake.sql),
/// so the phone and the Mac check their mailbox at once instead of on a timer.
///
/// The ping carries no data: packets are still fetched and decrypted through the normal mailbox calls. If the
/// channel can't be joined (migration not applied, network blocks websockets), `connected` stays false and callers
/// keep their old polling intervals.
@MainActor
final class CloudWake {
    let pulse = CloudPulse()
    private(set) var connected = false
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var device: UUID?
    private let network: URLSession
    private var frameRef = 1
    private var sentToken = ""

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        network = URLSession(configuration: configuration)
    }

    /// Keeps a channel open for `device` until `stop()`. Calling again for the same device does nothing.
    func start(device: UUID, token: @escaping @Sendable @MainActor () async throws -> String) {
        guard self.device != device || loop == nil else { return }
        stop()
        self.device = device
        loop = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                guard let self else { return }
                let opened = Date()
                do { try await self.run(device: device, token: token) } catch {}
                self.connected = false
                self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
                // A session that stayed up a while resets the backoff.
                backoff = Date().timeIntervalSince(opened) > 60 ? 1 : min(backoff * 2, 30)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connected = false; device = nil
    }

    private func run(device: UUID, token: @escaping @Sendable @MainActor () async throws -> String) async throws {
        guard let url = Self.socketURL() else { return }
        let socket = network.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        let topic = Self.topic(device)
        frameRef = 1
        sentToken = try await token()
        try await socket.send(.string(Self.joinFrame(topic: topic, token: sentToken, ref: "1")))
        let joinedBy = Date().addingTimeInterval(10)
        // Heartbeats keep the socket open; a refreshed sign-in token is passed on so the channel stays authorized.
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                self.frameRef += 1
                try? await socket.send(.string(Self.frame(topic: "phoenix", event: "heartbeat", payload: [:], ref: String(self.frameRef))))
                if !self.connected, Date() > joinedBy { socket.cancel(with: .goingAway, reason: nil); return }
                if let fresh = try? await token(), fresh != self.sentToken {
                    self.sentToken = fresh; self.frameRef += 1
                    try? await socket.send(.string(Self.frame(topic: topic, event: "access_token", payload: ["access_token": fresh], ref: String(self.frameRef))))
                }
            }
        }
        defer { heartbeat.cancel() }
        let joinTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, !self.connected else { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { joinTimeout.cancel() }
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message else { continue }
            switch Self.parse(text, topic: topic) {
            case .joined:
                connected = true
                // Anything stored while we were away: check now.
                pulse.signal()
            case .wake: pulse.signal()
            case .closed: return
            case .other: continue
            }
        }
    }

    // MARK: Frames (Phoenix protocol, vsn 1.0.0). Static so tests can check them without a network.

    enum Event: Equatable { case joined, wake, closed, other }

    nonisolated static func topic(_ device: UUID) -> String { "realtime:opengrok:" + device.uuidString.lowercased() }

    nonisolated static func socketURL() -> URL? {
        guard var parts = URLComponents(url: CloudConfiguration.url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "wss"; parts.path = "/realtime/v1/websocket"
        parts.queryItems = [URLQueryItem(name: "apikey", value: CloudConfiguration.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        return parts.url
    }

    nonisolated static func joinFrame(topic: String, token: String, ref: String) -> String {
        let payload: [String: Any] = [
            "config": ["broadcast": ["self": false, "ack": false], "presence": ["key": ""], "private": true],
            "access_token": token,
        ]
        return frame(topic: topic, event: "phx_join", payload: payload, ref: ref, joinRef: ref)
    }

    nonisolated static func frame(topic: String, event: String, payload: [String: Any], ref: String, joinRef: String? = nil) -> String {
        var object: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": ref]
        if let joinRef { object["join_ref"] = joinRef }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func parse(_ text: String, topic: String) -> Event {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let event = object["event"] as? String else { return .other }
        guard object["topic"] as? String == topic else { return .other }
        let payload = object["payload"] as? [String: Any]
        switch event {
        case "phx_reply":
            // Only the join is answered with the join's ref; heartbeats reply on the "phoenix" topic.
            guard object["ref"] as? String == "1" else { return .other }
            return payload?["status"] as? String == "ok" ? .joined : .closed
        case "broadcast": return .wake
        case "phx_close", "phx_error": return .closed
        case "system":
            return payload?["status"] as? String == "error" ? .closed : .other
        default: return .other
        }
    }
}
