import Foundation

/// Chat channels on the Mac (10.2): one Bot you choose answers messages that arrive on Telegram and on iMessage (through Inkbox),
/// with the same rules as the Windows app and the Docker server.
///
/// Nobody is answered until you approve them. A stranger who messages the Bot gets a 6-digit code and nothing else; the code does
/// nothing until you type it into Settings → Channels. Codes expire after an hour and each channel keeps at most 20 waiting.
/// Approved people are limited to 30 messages every 10 minutes, and a message is one Bot turn like any other: the Bot's own
/// approval cards still apply. Tokens are kept in the Keychain on this Mac.
enum MacChannelKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case telegram, imessage
    var id: String { rawValue }
    var name: String { self == .telegram ? "Telegram" : "iMessage" }
    var limit: Int { 4000 }
    struct Field: Identifiable, Sendable { let key: String; let label: String; let secret: Bool; let placeholder: String; var id: String { key } }
    var fields: [Field] {
        switch self {
        case .telegram: [Field(key: "token", label: "Bot token", secret: true, placeholder: "123456789:AA…")]
        case .imessage: [Field(key: "apiKey", label: "Inkbox API key", secret: true, placeholder: "ik_…")]
        }
    }
    var blurb: String {
        switch self {
        case .telegram: "Direct messages to a Telegram bot you make in a minute with @BotFather."
        case .imessage: "Your Bot gets its own iMessage identity through Inkbox, so people text it like a contact. Nothing on this Mac has to be reachable from outside."
        }
    }
    var steps: [String] {
        switch self {
        case .telegram: ["In Telegram, message @BotFather and send /newbot.", "Pick a name, then copy the token it gives you.", "Paste it below and turn the channel on."]
        case .imessage: ["Sign up at inkbox.ai and create an agent with iMessage turned on.", "Make an API key for that agent and paste it below.", "From your phone, text “connect @your-agent-handle” to the router number Inkbox shows you."]
        }
    }
    var guide: URL { URL(string: self == .telegram ? "https://core.telegram.org/bots/features#botfather" : "https://inkbox.ai")! }
}

struct MacChannelPerson: Codable, Equatable, Identifiable, Sendable { var id: String; var name: String; var at: Date; var chatID: String; var lastSeen: Date? }
struct MacChannelPending: Codable, Equatable, Identifiable, Sendable { var senderID: String; var name: String; var code: String; var at: Date; var chatID: String; var id: String { senderID } }
struct MacChannelConfig: Codable, Equatable, Sendable { var enabled = false; var fields: [String: String] = [:] }
struct MacChannelData: Codable, Equatable, Sendable {
    var bot: UUID?
    var channels: [String: MacChannelConfig] = [:]
    var approved: [String: [MacChannelPerson]] = [:]
    var pending: [String: [MacChannelPending]] = [:]
}

enum MacChannelState: Equatable, Sendable {
    case off, starting, on(String), failed(String)
    var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Connecting…"
        case .on(let detail): detail.isEmpty ? "On" : "On · \(detail)"
        case .failed(let detail): detail.isEmpty ? "Not working" : "Not working · \(detail)"
        }
    }
}

struct MacInboundMessage: Sendable { let channel: MacChannelKind; let senderID: String; let senderName: String; let chatID: String; let text: String }

struct MacChannelError: LocalizedError, Sendable { let message: String; var code = 0; var errorDescription: String? { message } }

/// The network side of one channel.
protocol MacChannelAdapter: Actor {
    func start() async throws -> String
    func stop()
    func send(chatID: String, text: String) async throws
    func typing(chatID: String) async
}

/// Splits a long answer into parts a chat app accepts, at paragraph, line or word breaks where it can.
enum MacChannelText {
    static func chunk(_ text: String, limit: Int) -> [String] {
        var parts: [String] = [], rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.range(of: "\n\n", options: .backwards)?.lowerBound ?? window.range(of: "\n", options: .backwards)?.lowerBound ?? window.range(of: " ", options: .backwards)?.lowerBound
            let end = cut.flatMap { window.distance(from: window.startIndex, to: $0) > limit / 2 ? $0 : nil } ?? window.endIndex
            parts.append(String(rest[rest.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...].drop { $0.isWhitespace }
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts.filter { !$0.isEmpty }
    }
}

@MainActor
final class MacChannels: ObservableObject {
    static let shared = MacChannels()
    static let pairTTL: TimeInterval = 3600, maxPending = 20, window: TimeInterval = 600, maxPerWindow = 30, maxText = 4000, noticeGap: TimeInterval = 600

    @Published private(set) var data = MacChannelData()
    @Published private(set) var states: [MacChannelKind: MacChannelState] = [:]
    @Published var feedback: String?

    private let store: KeychainSecretStore
    private var adapters: [MacChannelKind: any MacChannelAdapter] = [:]
    private var recent: [String: [Date]] = [:]
    private var notices: [String: Date] = [:]
    private var busy = false
    private var sent: [Date] = []
    private var loaded = false
    weak var desktop: MacAppModel?
    /// Replaced in tests.
    var makeAdapter: (@MainActor (MacChannelKind, [String: String], @escaping @Sendable (MacInboundMessage) async -> Void, @escaping @Sendable (MacChannelState) async -> Void) -> any MacChannelAdapter)?
    var ask: (@MainActor (UUID, String) async throws -> String)?
    var now: () -> Date = Date.init
    var makeCode: () -> String = { String(Int.random(in: 100_000...999_999)) }

    init(store: KeychainSecretStore = KeychainSecretStore(service: "org.opengrokbot.mac.channels")) { self.store = store }

    /// Loads saved settings and starts the channels that were on.
    func attach(desktop: MacAppModel) {
        self.desktop = desktop
        guard !loaded else { return }
        loaded = true
        if let saved = try? store.read(account: "settings"), let value = try? JSONDecoder().decode(MacChannelData.self, from: saved) { data = value }
        for kind in MacChannelKind.allCases where config(kind).enabled { start(kind) }
    }

    func config(_ kind: MacChannelKind) -> MacChannelConfig { data.channels[kind.rawValue] ?? MacChannelConfig() }
    func configured(_ kind: MacChannelKind) -> Bool { kind.fields.allSatisfy { !(config(kind).fields[$0.key] ?? "").isEmpty } }
    func state(_ kind: MacChannelKind) -> MacChannelState { states[kind] ?? (config(kind).enabled ? .starting : .off) }
    func approved(_ kind: MacChannelKind) -> [MacChannelPerson] { data.approved[kind.rawValue] ?? [] }
    func pending(_ kind: MacChannelKind) -> [MacChannelPending] { (data.pending[kind.rawValue] ?? []).filter { now().timeIntervalSince($0.at) < Self.pairTTL } }
    var anyOn: Bool { MacChannelKind.allCases.contains { config($0).enabled } }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        do { try store.save(encoded, account: "settings") } catch { feedback = "Channel settings could not be saved to the Keychain." }
    }

    // MARK: Settings

    func setBot(_ id: UUID?) { data.bot = id; persist() }

    /// Saves a channel's fields. Blank secret fields keep their saved value, so a token is never shown again just to keep it.
    func configure(_ kind: MacChannelKind, fields: [String: String]) throws {
        var current = config(kind)
        for field in kind.fields {
            guard let value = fields[field.key] else { continue }
            guard value.count <= 500, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw MacChannelError(message: "One of the values is not valid.") }
            let clean = value.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { current.fields[field.key] = clean } else if !field.secret { current.fields[field.key] = nil }
        }
        data.channels[kind.rawValue] = current; persist()
        if current.enabled { stop(kind); start(kind) }
    }

    func setEnabled(_ kind: MacChannelKind, _ on: Bool) throws {
        if on && !configured(kind) { throw MacChannelError(message: "Finish setting up \(kind.name) first.") }
        if on && data.bot == nil { throw MacChannelError(message: "Choose which Bot answers first.") }
        var current = config(kind); current.enabled = on
        data.channels[kind.rawValue] = current; persist()
        if on { start(kind) } else { stop(kind) }
    }

    private func start(_ kind: MacChannelKind) {
        guard adapters[kind] == nil else { return }
        let fields = config(kind).fields
        let deliver: @Sendable (MacInboundMessage) async -> Void = { message in await MacChannels.shared.inbound(message) }
        let report: @Sendable (MacChannelState) async -> Void = { [weak self] state in await MainActor.run { if self?.adapters[kind] != nil { self?.states[kind] = state } } }
        let adapter = makeAdapter?(kind, fields, deliver, report) ?? Self.defaultAdapter(kind, fields: fields, deliver: deliver, report: report)
        adapters[kind] = adapter; states[kind] = .starting
        Task {
            do { let detail = try await adapter.start(); if adapters[kind] === adapter { states[kind] = .on(detail) } }
            catch { if adapters[kind] === adapter { states[kind] = .failed(error.localizedDescription); adapters[kind] = nil } }
        }
    }

    private func stop(_ kind: MacChannelKind) {
        if let adapter = adapters.removeValue(forKey: kind) { Task { await adapter.stop() } }
        states[kind] = .off
    }

    func stopAll() { for kind in MacChannelKind.allCases { stop(kind) } }

    private static func defaultAdapter(_ kind: MacChannelKind, fields: [String: String], deliver: @escaping @Sendable (MacInboundMessage) async -> Void, report: @escaping @Sendable (MacChannelState) async -> Void) -> any MacChannelAdapter {
        switch kind {
        case .telegram: return TelegramChannel(token: fields["token"] ?? "", deliver: deliver, report: report)
        case .imessage: return InkboxChannel(key: fields["apiKey"] ?? "", deliver: deliver, report: report)
        }
    }

    // MARK: People

    /// You typed the code a person was given. They are approved from now on.
    @discardableResult
    func approve(_ kind: MacChannelKind, code: String) throws -> String {
        let wanted = code.trimmingCharacters(in: .whitespaces)
        guard let entry = pending(kind).first(where: { $0.code == wanted }) else { throw MacChannelError(message: "That code is not waiting. Ask them to message the Bot again to get a new one.") }
        data.pending[kind.rawValue] = pending(kind).filter { $0.senderID != entry.senderID }
        var list = approved(kind)
        if !list.contains(where: { $0.id == entry.senderID }) { list.append(MacChannelPerson(id: entry.senderID, name: entry.name, at: now(), chatID: entry.chatID)) }
        data.approved[kind.rawValue] = list; persist()
        Task { await send(kind, chatID: entry.chatID, text: "You’re approved. Send a message and the Bot will answer.") }
        return entry.name
    }

    func remove(_ kind: MacChannelKind, person: String) {
        data.approved[kind.rawValue] = approved(kind).filter { $0.id != person }
        data.pending[kind.rawValue] = pending(kind).filter { $0.senderID != person }
        persist()
    }

    private func send(_ kind: MacChannelKind, chatID: String, text: String) async {
        guard let adapter = adapters[kind] else { return }
        for part in MacChannelText.chunk(text, limit: kind.limit) { try? await adapter.send(chatID: chatID, text: part) }
    }

    // MARK: Messages

    func inbound(_ message: MacInboundMessage) async {
        let kind = message.channel, text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.senderID.isEmpty, !message.chatID.isEmpty, !text.isEmpty, let botID = data.bot, botExists(botID) else { return }
        let reply: (String) async -> Void = { body in await self.send(kind, chatID: message.chatID, text: body) }
        let key = kind.rawValue + ":" + message.senderID
        guard approved(kind).contains(where: { $0.id == message.senderID }) else {
            // Strangers get a code once in a while and nothing else. Nothing they write reaches the Bot.
            var list = pending(kind)
            var entry = list.first { $0.senderID == message.senderID }
            if entry == nil {
                guard list.count < Self.maxPending else { return }
                let made = MacChannelPending(senderID: message.senderID, name: String(message.senderName.prefix(80)), code: makeCode(), at: now(), chatID: message.chatID)
                list.append(made); data.pending[kind.rawValue] = list; persist(); entry = made
            }
            if now().timeIntervalSince(notices[key] ?? .distantPast) > Self.noticeGap, let entry {
                notices[key] = now()
                await reply("I only answer people my owner approved. Your code is \(entry.code). The owner enters it in Bothive, Settings > Channels.")
            }
            return
        }
        let times = (recent[key] ?? []).filter { now().timeIntervalSince($0) < Self.window }
        if times.count >= Self.maxPerWindow {
            if times.count == Self.maxPerWindow { recent[key] = times + [now()]; await reply("That is a lot of messages. Give it a few minutes.") }
            return
        }
        recent[key] = times + [now()]
        if var list = data.approved[kind.rawValue], let index = list.firstIndex(where: { $0.id == message.senderID }) {
            list[index].lastSeen = now(); list[index].chatID = message.chatID; data.approved[kind.rawValue] = list; persist()
        }
        if text.count > Self.maxText { await reply("That message is too long (the limit is \(Self.maxText) characters)."); return }
        if busy { await reply("Still working on the last message. I’ll answer that first."); return }
        busy = true
        defer { busy = false }
        if let adapter = adapters[kind] { await adapter.typing(chatID: message.chatID) }
        do {
            let tagged = "[\(kind.name) · \(String(message.senderName.prefix(60)))] \(text)"
            let answer: String
            if let ask { answer = try await ask(botID, tagged) } else { answer = try await askBot(botID, tagged) }
            await reply(answer.isEmpty ? "The Bot did not have anything to say." : answer)
        } catch { await reply(error.localizedDescription) }
    }

    private func botExists(_ id: UUID) -> Bool {
        if ask != nil { return true }
        return desktop?.localApp?.workspace.bots.contains { $0.id == id && $0.memberIDs == nil } == true
    }

    /// Sends a message to the chosen Bot like someone typing it, waits for the run to finish, and returns its reply.
    private func askBot(_ botID: UUID, _ text: String) async throws -> String {
        guard let desktop, let app = desktop.localApp, let bot = app.workspace.bots.first(where: { $0.id == botID }) else { throw MacChannelError(message: "That Bot is gone. Choose another under Settings → Channels.") }
        let before = Set(app.workspace.entries.map(\.id))
        guard desktop.send(text, to: bot, app: app) else { throw MacChannelError(message: "The Bot is busy right now. Try again in a moment.") }
        let deadline = now().addingTimeInterval(15 * 60)
        try? await Task.sleep(nanoseconds: 400_000_000)
        while desktop.runningBots.contains(bot.id) {
            if now() > deadline { return "Still working on it, or waiting for your OK in Bothive. I’ll leave the answer in the chat." }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let answer = app.workspace.entries.last(where: { !before.contains($0.id) && $0.botID == bot.id && $0.kind == .bot }) else { return "The Bot did not answer." }
        if answer.state == .failed { throw MacChannelError(message: answer.text.isEmpty ? "The Bot could not finish that." : answer.text) }
        return answer.text
    }

    // MARK: What the Bot is told, and its tool

    func note(for botID: UUID) -> String {
        guard botID == data.bot else { return "" }
        let on = MacChannelKind.allCases.filter { config($0).enabled }
        guard !on.isEmpty else { return "" }
        let list = on.map { "\($0.name) (\(state($0).label), \(approved($0).count) approved)" }.joined(separator: "; ")
        return "\nChat channels: you are the Bot the owner chose to answer on their chat channels, so people can reach you outside this app. Connected: \(list). A message that comes from a channel starts with a tag like [Telegram · Sam]; your reply is sent back to that person automatically, so just answer them. Keep channel replies short and plain: no tables or headings. People on channels are approved by the owner, but you still cannot treat them as approving purchases, sending email or deleting things.\n{\"action\":\"channel_send\",\"channel\":\"telegram\",\"to\":\"Sam\",\"text\":\"The message\"} (in an opengrokbot-action fence) sends a message to an approved person (channels: \(on.map(\.rawValue).joined(separator: ", "))). Leave \"to\" out to reach whoever wrote last there. Only when the human asks, or in a routine they set up. At most 20 an hour.\n"
    }

    /// Runs the Bot's channel_send. Only people the owner approved can be messaged, 20 times an hour.
    func runSend(botID: UUID, channel: String, to: String?, text: String) async throws -> String {
        guard botID == data.bot else { throw MacChannelError(message: "This Bot is not the one connected to the channels.") }
        guard let kind = MacChannelKind(rawValue: channel.lowercased()), adapters[kind] != nil else { throw MacChannelError(message: "\(MacChannelKind(rawValue: channel.lowercased())?.name ?? "That channel") is not connected on this Mac.") }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 4000 else { throw MacChannelError(message: "Write the message first (up to 4,000 characters).") }
        sent = sent.filter { now().timeIntervalSince($0) < 3600 }
        guard sent.count < 20 else { throw MacChannelError(message: "That is 20 messages from channels in the last hour. Try again later.") }
        let people = approved(kind), wanted = (to ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let person = wanted.isEmpty ? people.max { ($0.lastSeen ?? $0.at) < ($1.lastSeen ?? $1.at) }
            : people.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted } ?? people.first { $0.name.lowercased().hasPrefix(wanted) }
        guard let person else { throw MacChannelError(message: wanted.isEmpty ? "Nobody is approved on \(kind.name) yet." : "\(to ?? "") is not an approved person on \(kind.name).") }
        sent.append(now())
        await send(kind, chatID: person.chatID, text: body)
        return "Sent to \(person.name) on \(kind.name)."
    }
}

// MARK: - Telegram

/// A bot made with @BotFather. Direct messages only. Long polling, so nothing needs to be reachable from outside.
actor TelegramChannel: MacChannelAdapter {
    private let token: String
    private let deliver: @Sendable (MacInboundMessage) async -> Void
    private let report: @Sendable (MacChannelState) async -> Void
    private var loop: Task<Void, Never>?
    private var offset = 0
    private var username = ""

    init(token: String, deliver: @escaping @Sendable (MacInboundMessage) async -> Void, report: @escaping @Sendable (MacChannelState) async -> Void) {
        self.token = token; self.deliver = deliver; self.report = report
    }

    private func call(_ method: String, _ body: [String: Any], timeout: TimeInterval = 15) async throws -> Any? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw MacChannelError(message: "That token is not valid.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard reply["ok"] as? Bool == true else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MacChannelError(message: reply["description"] as? String ?? "Telegram answered \(status).", code: reply["error_code"] as? Int ?? status)
        }
        return reply["result"]
    }

    func start() async throws -> String {
        let me: Any?
        do { me = try await call("getMe", [:]) }
        catch let error as MacChannelError where error.code == 401 { throw MacChannelError(message: "Telegram did not accept that token. Copy it again from @BotFather.") }
        catch { throw MacChannelError(message: "Telegram could not be reached: \(error.localizedDescription)") }
        username = (me as? [String: Any])?["username"] as? String ?? "bot"
        loop = Task { await self.poll() }
        return "@" + username
    }

    func stop() { loop?.cancel(); loop = nil }

    private func poll() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            do {
                let updates = try await call("getUpdates", ["offset": offset, "timeout": 25, "allowed_updates": ["message"]], timeout: 40) as? [[String: Any]] ?? []
                delay = 1
                await report(.on("@" + username))
                for update in updates {
                    if let id = update["update_id"] as? Int { offset = max(offset, id + 1) }
                    guard let message = update["message"] as? [String: Any], let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                          let text = message["text"] as? String, let from = message["from"] as? [String: Any], from["is_bot"] as? Bool != true,
                          let sender = (from["id"] as? NSNumber)?.stringValue, let chatID = (chat["id"] as? NSNumber)?.stringValue else { continue }
                    let name = [from["first_name"] as? String, from["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
                    let inbound = MacInboundMessage(channel: .telegram, senderID: sender, senderName: name.isEmpty ? (from["username"] as? String ?? sender) : name, chatID: chatID, text: text)
                    let deliver = self.deliver
                    Task { await deliver(inbound) }
                }
            } catch {
                if Task.isCancelled { return }
                if (error as? MacChannelError)?.code == 401 { await report(.failed("Telegram did not accept the token.")); return }
                await report(.failed("Reconnecting: \(error.localizedDescription)"))
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    func send(chatID: String, text: String) async throws { _ = try await call("sendMessage", ["chat_id": chatID, "text": text]) }
    func typing(chatID: String) async { _ = try? await call("sendChatAction", ["chat_id": chatID, "action": "typing"]) }
}

// MARK: - iMessage through Inkbox

/// Inkbox (inkbox.ai) gives the Bot its own iMessage identity. Bothive checks Inkbox's inbox every few seconds and answers in the
/// same conversation. Direct messages from phone numbers only; group chats are ignored.
actor InkboxChannel: MacChannelAdapter {
    private let key: String
    private let deliver: @Sendable (MacInboundMessage) async -> Void
    private let report: @Sendable (MacChannelState) async -> Void
    private var loop: Task<Void, Never>?
    private var seen: Set<String> = []
    private static let base = "https://inkbox.ai/api/v1/imessage"

    init(key: String, deliver: @escaping @Sendable (MacInboundMessage) async -> Void, report: @escaping @Sendable (MacChannelState) async -> Void) {
        self.key = key; self.deliver = deliver; self.report = report
    }

    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil, idempotent: Bool = false) async throws -> Any? {
        guard let url = URL(string: Self.base + path) else { throw MacChannelError(message: "Bad Inkbox address.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method; request.setValue(key, forHTTPHeaderField: "X-API-Key")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if idempotent { request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key"); request.setValue("idempotency-replay", forHTTPHeaderField: "Prefer") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || (status == 403 && path.hasPrefix("/conversations?")) { throw MacChannelError(message: "Inkbox did not accept that API key. Make an API key for this agent in the Inkbox console and paste it again.", code: 401) }
        if status == 400 { throw MacChannelError(message: "iMessage is not turned on for this Inkbox agent. Turn it on in the Inkbox console, then switch it on again here.", code: 400) }
        if status == 429 { throw MacChannelError(message: "Inkbox says the message limit was reached. It resets on a rolling 24 hours.", code: 429) }
        guard (200..<300).contains(status) else { throw MacChannelError(message: "Inkbox answered \(status).", code: status) }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func unread() async throws -> [[String: Any]] {
        let list = try await api("/messages?limit=50&is_read=false") as? [[String: Any]] ?? []
        return list.filter { $0["direction"] as? String == "inbound" && $0["is_group"] as? Bool != true && $0["is_blocked"] as? Bool != true }.reversed()
    }

    func start() async throws -> String {
        guard key.count >= 10, !key.contains(" ") else { throw MacChannelError(message: "Paste the API key from the Inkbox console.") }
        _ = try await api("/conversations?limit=1")
        // What is already waiting is old. Only messages that arrive from now on are answered.
        for message in try await unread() { if let id = message["id"] as? String { seen.insert(id) } }
        loop = Task { await self.poll() }
        return "Connected to Inkbox"
    }

    func stop() { loop?.cancel(); loop = nil }

    private func poll() async {
        var wait: UInt64 = 4
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                var conversations: Set<String> = []
                for message in try await unread() {
                    guard let id = message["id"] as? String, !seen.contains(id) else { continue }
                    seen.insert(id)
                    guard let content = message["content"] as? String, !content.isEmpty, let number = message["remote_number"] as? String,
                          number.range(of: #"^\+[1-9]\d{6,14}$"#, options: .regularExpression) != nil, let conversation = message["conversation_id"] as? String else { continue }
                    conversations.insert(conversation)
                    let inbound = MacInboundMessage(channel: .imessage, senderID: number, senderName: number, chatID: conversation, text: content)
                    let deliver = self.deliver
                    Task { await deliver(inbound) }
                }
                for id in conversations { _ = try? await api("/mark-read", method: "POST", body: ["conversation_id": id]) }
                if seen.count > 1000 { seen = Set(seen.prefix(500)) }
                wait = 4
                await report(.on("Connected to Inkbox"))
            } catch {
                let code = (error as? MacChannelError)?.code ?? 0
                if code == 401 || code == 400 { await report(.failed(error.localizedDescription)); return }
                await report(.failed(code == 429 ? error.localizedDescription : "Reconnecting: \(error.localizedDescription)"))
                wait = code == 429 ? 60 : 16
            }
        }
    }

    func send(chatID: String, text: String) async throws { _ = try await api("/messages", method: "POST", body: ["conversation_id": chatID, "text": text], idempotent: true) }
    func typing(chatID: String) async { _ = try? await api("/typing", method: "POST", body: ["conversation_id": chatID]) }
}
