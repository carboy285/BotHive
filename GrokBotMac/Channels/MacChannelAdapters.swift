import Foundation

/// A message that arrived on a chat channel (10.1.2).
struct ChannelMessage: Sendable {
    let senderID: String
    let senderName: String
    let chatID: String
    let text: String
    var media: [ChannelMedia] = []
}

struct ChannelError: LocalizedError {
    let message: String
    var code = 0
    var retryAfter: Double?
    var errorDescription: String? { message }
}

/// One way of reaching the Bot: Telegram, Discord, Slack or iMessage (through Inkbox). Each connects out, so nothing has to be reachable from the internet.
@MainActor
protocol ChannelAdapter: AnyObject {
    var state: RemoteChannels.State { get set }
    func start() async throws
    func stop()
    func send(chat: String, text: String) async throws
    func typing(chat: String) async
    /// Shows that a message was read. Called for approved people only, before anything slow happens.
    func acknowledge(_ message: ChannelMessage) async
}

extension ChannelAdapter {
    func acknowledge(_ message: ChannelMessage) async {}
}

@MainActor
enum ChannelHTTP {
    /// A JSON request. Throws a ChannelError with the HTTP status as `code` for anything but 2xx.
    static func request(_ address: String, method: String = "GET", headers: [String: String] = [:], json: Any? = nil, timeout: TimeInterval = 20) async throws -> (status: Int, body: Any?, headers: [AnyHashable: Any]) {
        guard let url = URL(string: address) else { throw ChannelError(message: "That address is not valid.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var body: Any?
        if !data.isEmpty { body = try? JSONSerialization.jsonObject(with: data) }
        return (status, body, http?.allHeaderFields ?? [:])
    }
}

// MARK: Telegram

/// A bot made with @BotFather. Direct messages only. Long polling.
@MainActor
final class TelegramAdapter: ChannelAdapter {
    var state = RemoteChannels.State(state: "starting", detail: "")
    private let token: String
    private let onMessage: (ChannelMessage) -> Void
    private var task: Task<Void, Never>?
    private var offset = 0
    private var username = ""

    init(token: String, onMessage: @escaping (ChannelMessage) -> Void) { self.token = token; self.onMessage = onMessage }

    private func call(_ method: String, _ body: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> Any? {
        let reply = try await ChannelHTTP.request("https://api.telegram.org/bot\(token)/\(method)", method: "POST", json: body, timeout: timeout)
        guard let object = reply.body as? [String: Any], object["ok"] as? Bool == true else {
            let object = reply.body as? [String: Any]
            throw ChannelError(message: (object?["description"] as? String) ?? "Telegram answered \(reply.status).", code: (object?["error_code"] as? Int) ?? reply.status)
        }
        return object["result"]
    }

    func start() async throws {
        do {
            let me = try await call("getMe") as? [String: Any]
            username = (me?["username"] as? String) ?? ""
        } catch let error as ChannelError {
            throw ChannelError(message: error.code == 401 ? "Telegram did not accept that token. Copy it again from @BotFather." : "Telegram could not be reached: \(error.message)")
        }
        state = .init(state: "on", detail: "@" + username)
        task = Task { await loop() }
    }

    func stop() { task?.cancel(); task = nil; state = .init(state: "off", detail: "") }

    private func loop() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            do {
                let result = try await call("getUpdates", ["offset": offset, "timeout": 25, "allowed_updates": ["message"]], timeout: 40) as? [[String: Any]] ?? []
                delay = 1; state = .init(state: "on", detail: "@" + username)
                for update in result {
                    offset = max(offset, ((update["update_id"] as? Int) ?? 0) + 1)
                    guard let message = update["message"] as? [String: Any],
                          let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                          let from = message["from"] as? [String: Any], from["is_bot"] as? Bool != true,
                          let sender = from["id"] as? Int, let chatID = chat["id"] as? Int else { continue }
                    let text = (message["text"] as? String) ?? (message["caption"] as? String) ?? ""
                    let media = await pictures(in: message)
                    guard !text.isEmpty || !media.isEmpty else { continue }
                    let name = [from["first_name"] as? String, from["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
                    onMessage(ChannelMessage(senderID: String(sender), senderName: name.isEmpty ? ((from["username"] as? String) ?? String(sender)) : name, chatID: String(chatID), text: text, media: media))
                }
            } catch let error as ChannelError {
                if Task.isCancelled { return }
                if error.code == 401 { state = .init(state: "error", detail: "Telegram no longer accepts this token."); return }
                state = .init(state: "error", detail: error.code == 409 ? "Another program is reading this Telegram bot. Stop it, or make a new bot." : "Reconnecting: \(error.message)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000); delay = min(delay * 2, 30)
            } catch {
                if Task.isCancelled { return }
                state = .init(state: "error", detail: "Reconnecting: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000); delay = min(delay * 2, 30)
            }
        }
    }

    /// The picture on a message (the largest size), or an image sent as a file. Telegram needs a lookup to get the download address.
    private func pictures(in message: [String: Any]) async -> [ChannelMedia] {
        var ids: [(String, String, String)] = []
        if let sizes = message["photo"] as? [[String: Any]], let best = sizes.last, let id = best["file_id"] as? String { ids.append((id, "image/jpeg", "Photo")) }
        if let document = message["document"] as? [String: Any], let id = document["file_id"] as? String, let type = document["mime_type"] as? String, type.hasPrefix("image/") {
            ids.append((id, type, (document["file_name"] as? String) ?? "Image"))
        }
        var out: [ChannelMedia] = []
        for (id, type, name) in ids {
            if let file = try? await call("getFile", ["file_id": id]) as? [String: Any], let path = file["file_path"] as? String {
                out.append(ChannelMedia(url: "https://api.telegram.org/file/bot\(token)/\(path)", contentType: type, name: name))
            }
        }
        return out
    }

    func send(chat: String, text: String) async throws { _ = try await call("sendMessage", ["chat_id": chat, "text": text, "disable_web_page_preview": true]) }
    func typing(chat: String) async { _ = try? await call("sendChatAction", ["chat_id": chat, "action": "typing"], timeout: 8) }
}

// MARK: Discord

/// A bot made in the Discord developer portal (Message Content Intent on). Direct messages, and in a server only when @mentioned.
@MainActor
final class DiscordAdapter: ChannelAdapter {
    var state = RemoteChannels.State(state: "starting", detail: "")
    private let token: String
    private let onMessage: (ChannelMessage) -> Void
    private var running = false
    private var socket: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var sequence: Int?
    private var userID = ""
    private var username = ""
    private var backoff: UInt64 = 1
    private static let intents = (1 << 9) | (1 << 12) | (1 << 15)

    init(token: String, onMessage: @escaping (ChannelMessage) -> Void) { self.token = token; self.onMessage = onMessage }

    private var headers: [String: String] { ["Authorization": "Bot " + token] }

    private func rest(_ path: String, method: String = "GET", json: Any? = nil) async throws -> Any? {
        let reply = try await ChannelHTTP.request("https://discord.com/api/v10" + path, method: method, headers: headers, json: json)
        if reply.status == 401 { throw ChannelError(message: "Discord did not accept that token. Copy it again from the bot page.", code: 401) }
        if reply.status == 429 {
            let wait = ((reply.body as? [String: Any])?["retry_after"] as? Double) ?? 1
            try await Task.sleep(nanoseconds: UInt64(min(wait, 5) * 1_000_000_000))
            return try await rest(path, method: method, json: json)
        }
        guard (200..<300).contains(reply.status) else { throw ChannelError(message: "Discord answered \(reply.status).", code: reply.status) }
        return reply.body
    }

    func start() async throws {
        running = true
        let me = try await rest("/users/@me") as? [String: Any]
        userID = (me?["id"] as? String) ?? ""; username = (me?["username"] as? String) ?? ""
        connect()
    }

    func stop() { running = false; heartbeat?.cancel(); receiving?.cancel(); socket?.cancel(with: .normalClosure, reason: nil); socket = nil; state = .init(state: "off", detail: "") }

    private func connect() {
        guard running, let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json") else { return }
        state = .init(state: "starting", detail: "Connecting\u{2026}")
        sequence = nil
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task; task.resume()
        receiving = Task { await receiveLoop(task) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while running, !Task.isCancelled, socket === task {
            do {
                let message = try await task.receive()
                var text = ""
                switch message { case .string(let value): text = value; case .data(let data): text = String(decoding: data, as: UTF8.self); @unknown default: break }
                if let packet = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { handle(packet) }
            } catch {
                heartbeat?.cancel()
                guard running, socket === task else { return }
                let code = task.closeCode.rawValue
                if code == 4004 { running = false; state = .init(state: "error", detail: "Discord did not accept that token."); return }
                if code == 4014 || code == 4013 { running = false; state = .init(state: "error", detail: "Turn on \u{201C}Message Content Intent\u{201D} for this bot in the Discord developer portal, then switch it on again."); return }
                state = .init(state: "error", detail: backoff >= 4 ? "Reconnecting\u{2026} If this keeps happening, turn on \u{201C}Message Content Intent\u{201D} for this bot in the Discord developer portal." : "Reconnecting\u{2026}")
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000); backoff = min(backoff * 2, 30)
                connect(); return
            }
        }
    }

    private func sendOp(_ op: Int, _ data: Any) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["op": op, "d": data]), let text = String(data: payload, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func handle(_ packet: [String: Any]) {
        if let s = packet["s"] as? Int { sequence = s }
        let op = packet["op"] as? Int ?? -1
        if op == 10 {
            let interval = ((packet["d"] as? [String: Any])?["heartbeat_interval"] as? Double) ?? 41_250
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 0.5 * 1_000_000))
                while !Task.isCancelled {
                    guard let self else { return }
                    let current: Any = self.sequence.map { $0 as Any } ?? NSNull()
                    self.sendOp(1, current)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000))
                }
            }
            sendOp(2, ["token": token, "intents": Self.intents, "properties": ["os": "bothive", "browser": "bothive", "device": "bothive"]])
        } else if op == 7 || op == 9 {
            socket?.cancel(with: .goingAway, reason: nil)
        } else if op == 0, let type = packet["t"] as? String, let data = packet["d"] as? [String: Any] {
            if type == "READY" {
                userID = ((data["user"] as? [String: Any])?["id"] as? String) ?? userID
                backoff = 1; state = .init(state: "on", detail: username.isEmpty ? "Connected" : "Bot " + username)
            } else if type == "MESSAGE_CREATE" { message(data) }
        }
    }

    private func message(_ data: [String: Any]) {
        guard var text = data["content"] as? String, let author = data["author"] as? [String: Any], let authorID = author["id"] as? String,
              author["bot"] as? Bool != true, authorID != userID, let channel = data["channel_id"] as? String else { return }
        if data["guild_id"] != nil {
            let mentioned = ((data["mentions"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == userID }
            let tag1 = "<@\(userID)>", tag2 = "<@!\(userID)>"
            guard mentioned || text.contains(tag1) || text.contains(tag2) else { return }
            text = text.replacingOccurrences(of: tag1, with: "").replacingOccurrences(of: tag2, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let media = ((data["attachments"] as? [[String: Any]]) ?? []).compactMap { item -> ChannelMedia? in
            guard let url = item["url"] as? String, let type = item["content_type"] as? String, type.hasPrefix("image/") else { return nil }
            return ChannelMedia(url: url, contentType: type, name: (item["filename"] as? String) ?? "Image")
        }
        guard !text.isEmpty || !media.isEmpty else { return }
        onMessage(ChannelMessage(senderID: authorID, senderName: (author["global_name"] as? String) ?? (author["username"] as? String) ?? authorID, chatID: channel, text: text, media: media))
    }

    func send(chat: String, text: String) async throws { _ = try await rest("/channels/\(chat)/messages", method: "POST", json: ["content": text, "allowed_mentions": ["parse": [String]()]]) }
    func typing(chat: String) async { _ = try? await rest("/channels/\(chat)/typing", method: "POST") }
}

// MARK: Slack

/// An app with Socket Mode on: a bot token (xoxb-) and an app-level token (xapp-). Direct messages, and in a channel only when @mentioned.
@MainActor
final class SlackAdapter: ChannelAdapter {
    var state = RemoteChannels.State(state: "starting", detail: "")
    private let botToken: String
    private let appToken: String
    private let onMessage: (ChannelMessage) -> Void
    private var running = false
    private var socket: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?
    private var userID = ""
    private var team = ""
    private var seen: [String] = []
    private var backoff: UInt64 = 1

    init(botToken: String, appToken: String, onMessage: @escaping (ChannelMessage) -> Void) { self.botToken = botToken; self.appToken = appToken; self.onMessage = onMessage }

    private func api(_ method: String, token: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        let reply = try await ChannelHTTP.request("https://slack.com/api/\(method)", method: "POST", headers: ["Authorization": "Bearer " + token], json: body)
        let object = (reply.body as? [String: Any]) ?? [:]
        guard object["ok"] as? Bool == true else { throw ChannelError(message: (object["error"] as? String) ?? "Slack answered \(reply.status).") }
        return object
    }

    func start() async throws {
        guard botToken.hasPrefix("xoxb-") else { throw ChannelError(message: "The bot token starts with xoxb-. Copy it from OAuth & Permissions.") }
        guard appToken.hasPrefix("xapp-") else { throw ChannelError(message: "The app token starts with xapp-. Make one under Basic Information \u{2192} App-Level Tokens with connections:write.") }
        do {
            let who = try await api("auth.test", token: botToken)
            userID = (who["user_id"] as? String) ?? ""; team = (who["team"] as? String) ?? ""
        } catch let error as ChannelError {
            throw ChannelError(message: error.message == "invalid_auth" ? "Slack did not accept the bot token." : "Slack could not be reached: \(error.message)")
        }
        running = true
        await connect()
    }

    func stop() { running = false; receiving?.cancel(); socket?.cancel(with: .normalClosure, reason: nil); socket = nil; state = .init(state: "off", detail: "") }

    private func connect() async {
        guard running else { return }
        do {
            let opened = try await api("apps.connections.open", token: appToken)
            guard let address = opened["url"] as? String, let url = URL(string: address) else { throw ChannelError(message: "Slack did not give a connection address.") }
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task; task.resume()
            receiving = Task { await receiveLoop(task) }
        } catch let error as ChannelError {
            if error.message == "invalid_auth" || error.message == "not_allowed_token_type" { running = false; state = .init(state: "error", detail: "Slack did not accept the app token (it needs connections:write)."); return }
            state = .init(state: "error", detail: "Reconnecting\u{2026}")
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000); backoff = min(backoff * 2, 30)
            await connect()
        } catch {
            state = .init(state: "error", detail: "Reconnecting\u{2026}")
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000); backoff = min(backoff * 2, 30)
            await connect()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while running, !Task.isCancelled, socket === task {
            do {
                let message = try await task.receive()
                var text = ""
                switch message { case .string(let value): text = value; case .data(let data): text = String(decoding: data, as: UTF8.self); @unknown default: break }
                if let packet = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { handle(packet, task) }
            } catch {
                guard running, socket === task else { return }
                state = .init(state: "error", detail: "Reconnecting\u{2026}")
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000); backoff = min(backoff * 2, 30)
                await connect(); return
            }
        }
    }

    private func handle(_ packet: [String: Any], _ task: URLSessionWebSocketTask) {
        let type = packet["type"] as? String
        if type == "hello" { backoff = 1; state = .init(state: "on", detail: team.isEmpty ? "Connected" : "Workspace " + team); return }
        if type == "disconnect" { task.cancel(with: .goingAway, reason: nil); return }
        if let envelope = packet["envelope_id"] as? String, let ack = try? JSONSerialization.data(withJSONObject: ["envelope_id": envelope]), let text = String(data: ack, encoding: .utf8) { task.send(.string(text)) { _ in } }
        guard type == "events_api", let payload = packet["payload"] as? [String: Any], let event = payload["event"] as? [String: Any] else { return }
        let eventType = event["type"] as? String
        let direct = eventType == "message" && event["channel_type"] as? String == "im"
        guard direct || eventType == "app_mention" else { return }
        guard event["bot_id"] == nil, event["subtype"] == nil || event["subtype"] as? String == "file_share", let user = event["user"] as? String, user != userID,
              let channel = event["channel"] as? String else { return }
        var text = (event["text"] as? String) ?? ""
        if let id = (payload["event_id"] as? String) ?? (event["client_msg_id"] as? String) ?? (event["ts"] as? String) {
            if seen.contains(id) { return }
            seen.append(id); if seen.count > 500 { seen.removeFirst() }
        }
        text = text.replacingOccurrences(of: "<@\(userID)>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Pictures need the files:read scope; Slack wants the bot token on the download.
        let media = ((event["files"] as? [[String: Any]]) ?? []).compactMap { file -> ChannelMedia? in
            guard let url = file["url_private"] as? String, let type = file["mimetype"] as? String, type.hasPrefix("image/") else { return nil }
            return ChannelMedia(url: url, contentType: type, name: (file["name"] as? String) ?? "Image", headers: ["Authorization": "Bearer " + botToken])
        }
        guard !text.isEmpty || !media.isEmpty else { return }
        onMessage(ChannelMessage(senderID: user, senderName: user, chatID: channel, text: text, media: media))
    }

    func send(chat: String, text: String) async throws { _ = try await api("chat.postMessage", token: botToken, ["channel": chat, "text": text, "unfurl_links": false, "unfurl_media": false]) }
    func typing(chat: String) async {}
}

// MARK: iMessage through Inkbox

/// iMessage through Inkbox (inkbox.ai): a hosted service that gives an agent its own iMessage identity. Bothive checks its inbox every few
/// seconds and answers in the same conversation. Direct messages only; group chats are ignored.
@MainActor
final class InkboxIMessageAdapter: ChannelAdapter {
    var state = RemoteChannels.State(state: "starting", detail: "")
    private let apiKey: String
    private let onMessage: (ChannelMessage) -> Void
    private var task: Task<Void, Never>?
    private var seen = Set<String>()
    /// Conversations whose messages were passed on but not yet marked read. Approved people are marked read at once by `acknowledge`; the rest a little later.
    private var unacked: [String: Date] = [:]
    private static let base = "https://inkbox.ai/api/v1/imessage"

    init(apiKey: String, onMessage: @escaping (ChannelMessage) -> Void) { self.apiKey = apiKey; self.onMessage = onMessage }

    private func api(_ path: String, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]) async throws -> Any? {
        let reply = try await ChannelHTTP.request(Self.base + path, method: method, headers: ["X-API-Key": apiKey].merging(headers) { _, new in new }, json: json)
        switch reply.status {
        case 401: throw ChannelError(message: "Inkbox did not accept that API key. Make an API key for this agent in the Inkbox console and paste it again.", code: 401)
        case 403 where path.hasPrefix("/conversations?"): throw ChannelError(message: "Inkbox did not accept that API key. Make an API key for this agent in the Inkbox console and paste it again.", code: 401)
        case 400: throw ChannelError(message: "iMessage is not turned on for this Inkbox agent. Turn it on in the Inkbox console (the agent\u{2019}s settings), then switch it on again here.", code: 400)
        case 429:
            var wait = 60.0
            if let value = reply.headers["Retry-After"] as? String, let seconds = Double(value) { wait = seconds }
            throw ChannelError(message: "Inkbox says the message limit was reached. It resets on a rolling 24 hours.", code: 429, retryAfter: wait)
        case 200..<300: return reply.body
        default:
            let detail = ((reply.body as? [String: Any])?["detail"] as? [String: Any])?["error"] as? String
            throw ChannelError(message: "Inkbox answered \(reply.status)" + (detail.map { ": " + $0 } ?? "") + ".", code: reply.status)
        }
    }

    /// Unread, incoming, one-to-one messages, oldest first.
    private func unread() async throws -> [[String: Any]] {
        let list = try await api("/messages?limit=50&is_read=false") as? [[String: Any]] ?? []
        return list.filter { $0["direction"] as? String == "inbound" && $0["is_group"] as? Bool != true && $0["is_blocked"] as? Bool != true }.reversed()
    }

    func start() async throws {
        guard apiKey.count >= 10, !apiKey.contains(" ") else { throw ChannelError(message: "Paste the API key from the Inkbox console.") }
        do { _ = try await api("/conversations?limit=1") }
        catch let error as ChannelError { throw error }
        catch { throw ChannelError(message: "Inkbox could not be reached: \(error.localizedDescription)") }
        // What is already waiting is old. Only messages that arrive from now on are answered.
        for message in try await unread() { if let id = message["id"] as? String { seen.insert(id) } }
        state = .init(state: "on", detail: "Connected to Inkbox")
        task = Task { await loop() }
    }

    func stop() { task?.cancel(); task = nil; state = .init(state: "off", detail: "") }

    private func loop() async {
        while !Task.isCancelled {
            var wait: UInt64 = 2
            do {
                for message in try await unread() {
                    guard let id = message["id"] as? String, !seen.contains(id) else { continue }
                    seen.insert(id)
                    let media = ((message["media"] as? [[String: Any]]) ?? []).compactMap { item -> ChannelMedia? in
                        guard let url = item["url"] as? String else { return nil }
                        let type = (item["content_type"] as? String) ?? ""
                        return (type.isEmpty || type.hasPrefix("image/")) ? ChannelMedia(url: url, contentType: type, name: "Photo") : nil
                    }
                    // A sender that is not a phone number cannot be answered, so it is not passed on.
                    let text = (message["content"] as? String) ?? ""
                    guard !text.isEmpty || !media.isEmpty, let number = message["remote_number"] as? String,
                          number.range(of: #"^\+[1-9]\d{6,14}$"#, options: .regularExpression) != nil, let conversation = message["conversation_id"] as? String else { continue }
                    unacked[conversation] = Date()
                    onMessage(ChannelMessage(senderID: number, senderName: number, chatID: conversation, text: text, media: media))
                }
                // Messages from people nobody approved are marked read too, a little later, so they never clog the unread list.
                for (conversation, at) in unacked where Date().timeIntervalSince(at) > 30 {
                    unacked[conversation] = nil
                    _ = try? await api("/mark-read", method: "POST", json: ["conversation_id": conversation])
                }
                if seen.count > 1000 { seen = Set(seen.suffix(500)) }
                state = .init(state: "on", detail: "Connected to Inkbox")
            } catch let error as ChannelError {
                if Task.isCancelled { return }
                if error.code == 401 || error.code == 400 { state = .init(state: "error", detail: error.message); return }
                state = .init(state: "error", detail: error.code == 429 ? error.message : "Reconnecting: \(error.message)")
                wait = error.retryAfter.map { UInt64(min($0, 300)) } ?? 8
            } catch {
                if Task.isCancelled { return }
                state = .init(state: "error", detail: "Reconnecting: \(error.localizedDescription)"); wait = 8
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }

    func acknowledge(_ message: ChannelMessage) async {
        unacked[message.chatID] = nil
        _ = try? await api("/mark-read", method: "POST", json: ["conversation_id": message.chatID])
    }

    func send(chat: String, text: String) async throws {
        _ = try await api("/messages", method: "POST", json: ["conversation_id": chat, "text": text], headers: ["Idempotency-Key": UUID().uuidString, "Prefer": "idempotency-replay"])
    }
    func typing(chat: String) async { _ = try? await api("/typing", method: "POST", json: ["conversation_id": chat]) }
}
