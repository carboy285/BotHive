import Foundation

/// Chat channels on this Mac (10.1.2): one Bot you choose answers Telegram, Discord, Slack and iMessage (through Inkbox).
///
/// Safety first. A channel is a way to reach a Bot that can run tasks on this Mac, so nobody is answered until you approve them:
///  - A stranger gets a short code and nothing else. The code does nothing until you approve that person in Settings → Channels.
///    Codes last an hour, and each channel keeps at most 20 waiting.
///  - Approved people are rate limited, and a message is one Bot turn like any other (the Bot's own permission prompts still apply).
///  - In a Discord server or Slack channel the Bot only answers when it is @mentioned.
/// SMS and phone calls need a public address, so they run on a Bothive server rather than here.
@MainActor
final class MacChannels: ObservableObject {
    struct Person: Codable, Equatable {
        var id: String
        var name: String
        var chatID: String
        var at: Date
        var lastSeen: Date?
    }
    struct ChannelConfig: Codable {
        var enabled = false
        var fields: [String: String] = [:]
    }
    struct Config: Codable {
        var bot: String?
        var channels: [String: ChannelConfig] = [:]
        var approved: [String: [Person]] = [:]
    }
    struct Waiting {
        var senderID: String
        var name: String
        var code: String
        var chatID: String
        var at: Date
    }
    struct Info {
        let id: String
        let name: String
        let limit: Int
        let required: [String]
    }

    static let infos: [Info] = [
        Info(id: "telegram", name: "Telegram", limit: 4000, required: ["token"]),
        Info(id: "discord", name: "Discord", limit: 1900, required: ["token"]),
        Info(id: "slack", name: "Slack", limit: 3000, required: ["botToken", "appToken"]),
        Info(id: "imessage", name: "iMessage", limit: 4000, required: ["apiKey"]),
    ]
    private static let pairTTL: TimeInterval = 3600, maxPending = 20, window: TimeInterval = 600, maxPerWindow = 30, maxText = 4000, noticeGap: TimeInterval = 600

    @Published private(set) var config = Config()
    @Published private(set) var pending: [String: [Waiting]] = [:]
    weak var desktop: MacAppModel?
    weak var app: AppModel?
    private var adapters: [String: any ChannelAdapter] = [:]
    private var recent: [String: [Date]] = [:]
    private var notices: [String: Date] = [:]
    private var sentLog: [Date] = []
    private var busy = false
    private let store = KeychainSecretStore(service: "org.opengrokbot.mac.channels")

    static func isSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["token", "secret", "password", "key", "pin"].contains { lower.contains($0) }
    }
    static func info(_ id: String) -> Info? { infos.first { $0.id == id } }

    // MARK: Setup

    func attach(desktop: MacAppModel, app: AppModel) {
        self.desktop = desktop; self.app = app
        if let data = try? store.read(account: "config"), let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
        for info in Self.infos where config.channels[info.id]?.enabled == true { start(info.id) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { try? store.save(data, account: "config") }
    }

    private func botExists(_ id: String) -> Bool {
        app?.workspace.bots.contains { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame && $0.memberIDs == nil } ?? false
    }

    private func configured(_ id: String) -> Bool {
        guard let info = Self.info(id) else { return false }
        return info.required.allSatisfy { !(config.channels[id]?.fields[$0] ?? "").isEmpty }
    }

    /// What the settings screen shows. Secrets never leave: only whether each one is set.
    func status() -> RemoteChannels {
        var channels: [String: RemoteChannels.Channel] = [:]
        for info in Self.infos {
            let saved = config.channels[info.id] ?? ChannelConfig()
            var fields: [String: RemoteChannels.FieldValue] = [:]
            for (key, value) in saved.fields { fields[key] = Self.isSecret(key) ? .isSet(!value.isEmpty) : .text(value) }
            let state = adapters[info.id]?.state ?? RemoteChannels.State(state: saved.enabled ? "starting" : "off", detail: "")
            channels[info.id] = RemoteChannels.Channel(
                name: info.name, enabled: saved.enabled, configured: configured(info.id), fields: fields, state: state,
                approved: (config.approved[info.id] ?? []).map { RemoteChannels.Approved(id: $0.id, name: $0.name) },
                pending: live(info.id).map { RemoteChannels.Waiting(name: $0.name, code: $0.code) })
        }
        let bots = (app?.workspace.bots ?? []).filter { $0.memberIDs == nil }.map { RemoteChannels.BotChoice(id: $0.id.uuidString, name: $0.name) }
        return RemoteChannels(bot: config.bot, bots: bots, channels: channels, calls: RemoteChannels.Calls(ready: false, listening: false))
    }

    /// The same commands the Windows app and Docker server take, so one screen manages either.
    func execute(_ action: String, channel: String?, text: String?, fields: [String: String]?) async -> String? {
        do {
            switch action {
            case "channels_set_bot": try setBot(text ?? "")
            case "channels_configure": try await configure(channel, fields ?? [:])
            case "channels_enable": try await setEnabled(channel, on: text == "on")
            case "channels_approve": try approve(channel, code: text ?? "")
            case "channels_remove": remove(channel, id: text ?? "")
            case "channels_test_call": throw ChannelError(message: "SMS and phone calls need a public address, so they run on a Bothive server. Set them up there.")
            default: throw ChannelError(message: "Unknown channels command.")
            }
            return nil
        } catch { return error.localizedDescription }
    }

    private func setBot(_ id: String) throws {
        if id.isEmpty { config.bot = nil } else {
            guard botExists(id) else { throw ChannelError(message: "Choose one of your Bots.") }
            config.bot = id.uppercased()
        }
        save(); objectWillChange.send()
    }

    private func configure(_ id: String?, _ fields: [String: String]) async throws {
        guard let id, Self.info(id) != nil else { throw ChannelError(message: "Unknown channel.") }
        var current = config.channels[id] ?? ChannelConfig()
        for (key, value) in fields {
            guard value.count <= 500, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { throw ChannelError(message: "One of the values is not valid.") }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { current.fields[key] = clean } else if !Self.isSecret(key) { current.fields[key] = nil }
        }
        config.channels[id] = current; save()
        if current.enabled { stop(id); start(id) }
        objectWillChange.send()
    }

    private func setEnabled(_ id: String?, on: Bool) async throws {
        guard let id, let info = Self.info(id) else { throw ChannelError(message: "Unknown channel.") }
        if on {
            guard configured(id) else { throw ChannelError(message: "Finish setting up \(info.name) first.") }
            guard let bot = config.bot, botExists(bot) else { throw ChannelError(message: "Choose which Bot answers first.") }
        }
        var current = config.channels[id] ?? ChannelConfig()
        current.enabled = on; config.channels[id] = current; save()
        if on { start(id) } else { stop(id) }
        objectWillChange.send()
    }

    private func start(_ id: String) {
        guard adapters[id] == nil, let fields = config.channels[id]?.fields else { return }
        let handler: (ChannelMessage) -> Void = { [weak self] message in Task { @MainActor in await self?.inbound(id, message) } }
        let adapter: any ChannelAdapter
        switch id {
        case "telegram": adapter = TelegramAdapter(token: fields["token"] ?? "", onMessage: handler)
        case "discord": adapter = DiscordAdapter(token: fields["token"] ?? "", onMessage: handler)
        case "slack": adapter = SlackAdapter(botToken: fields["botToken"] ?? "", appToken: fields["appToken"] ?? "", onMessage: handler)
        case "imessage": adapter = InkboxIMessageAdapter(apiKey: fields["apiKey"] ?? "", onMessage: handler)
        default: return
        }
        adapters[id] = adapter
        Task {
            do { try await adapter.start() } catch { adapter.state = RemoteChannels.State(state: "error", detail: error.localizedDescription) }
            self.objectWillChange.send()
        }
    }

    private func stop(_ id: String) { adapters[id]?.stop(); adapters[id] = nil }

    // MARK: People

    private func live(_ id: String) -> [Waiting] { (pending[id] ?? []).filter { Date().timeIntervalSince($0.at) < Self.pairTTL } }

    private func approve(_ id: String?, code: String) throws {
        guard let id, Self.info(id) != nil else { throw ChannelError(message: "Unknown channel.") }
        guard let entry = live(id).first(where: { $0.code == code.trimmingCharacters(in: .whitespaces) }) else { throw ChannelError(message: "That code is not waiting. Ask them to message the Bot again to get a new one.") }
        pending[id] = live(id).filter { $0.code != entry.code }
        var list = config.approved[id] ?? []
        if !list.contains(where: { $0.id == entry.senderID }) { list.append(Person(id: entry.senderID, name: entry.name, chatID: entry.chatID, at: Date())) }
        config.approved[id] = list; save()
        Task { await self.send(id, chat: entry.chatID, text: "You\u{2019}re approved. Send a message and the Bot will answer.") }
    }

    private func remove(_ id: String?, id person: String) {
        guard let id else { return }
        config.approved[id] = (config.approved[id] ?? []).filter { $0.id != person }
        pending[id] = live(id).filter { $0.senderID != person }
        save(); objectWillChange.send()
    }

    private func isApproved(_ channel: String, _ sender: String) -> Bool { (config.approved[channel] ?? []).contains { $0.id == sender } }

    /// Splits text into pieces of at most `limit` characters, at a blank line, a new line or a space where it can.
    static func chunks(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.count > limit {
            let head = String(rest.prefix(limit))
            var cut = head.count
            for separator in ["\n\n", "\n", " "] {
                if let range = head.range(of: separator, options: .backwards), head.distance(from: head.startIndex, to: range.lowerBound) > Int(Double(limit) * 0.4) {
                    cut = head.distance(from: head.startIndex, to: range.lowerBound); break
                }
            }
            out.append(String(rest.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = String(rest.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private func send(_ channel: String, chat: String, text: String) async {
        guard let adapter = adapters[channel], let info = Self.info(channel) else { return }
        for piece in Self.chunks(text, limit: info.limit) { try? await adapter.send(chat: chat, text: piece) }
    }

    // MARK: Messages

    private static let callWords = try! NSRegularExpression(pattern: #"^\s*(?:/call|(?:hey\s+)?(?:please\s+)?(?:can\s+you\s+|could\s+you\s+)?(?:give\s+me\s+a\s+)?(?:call|phone|ring)(?:\s+me)?(?:\s+now|\s+please)?[.!?]*)\s*$"#, options: .caseInsensitive)

    func inbound(_ channel: String, _ message: ChannelMessage) async {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = Self.info(channel), !text.isEmpty, let bot = config.bot, botExists(bot) else { return }
        if !isApproved(channel, message.senderID) {
            // Strangers get a code once in a while and nothing else. Nothing they write reaches the Bot.
            let now = Date(), key = channel + ":" + message.senderID
            var entry = live(channel).first { $0.senderID == message.senderID }
            if entry == nil {
                let list = live(channel)
                guard list.count < Self.maxPending else { return }
                let created = Waiting(senderID: message.senderID, name: String(message.senderName.prefix(80)), code: String(Int.random(in: 100_000...999_999)), chatID: message.chatID, at: now)
                pending[channel] = list + [created]; entry = created
            }
            if now.timeIntervalSince(notices[key] ?? .distantPast) > Self.noticeGap, let entry {
                notices[key] = now
                await send(channel, chat: message.chatID, text: "I only answer people my owner approved. Your code is \(entry.code). The owner enters it in Bothive, Settings > Channels.")
            }
            return
        }
        let now = Date(), key = channel + ":" + message.senderID
        var times = (recent[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        if times.count >= Self.maxPerWindow {
            if times.count == Self.maxPerWindow { times.append(now); recent[key] = times; await send(channel, chat: message.chatID, text: "That is a lot of messages. Give it a few minutes.") }
            return
        }
        times.append(now); recent[key] = times
        if var list = config.approved[channel], let index = list.firstIndex(where: { $0.id == message.senderID }) { list[index].lastSeen = now; list[index].chatID = message.chatID; config.approved[channel] = list }
        if text.count > Self.maxText { await send(channel, chat: message.chatID, text: "That message is too long (the limit is \(Self.maxText) characters)."); return }
        if Self.callWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            await send(channel, chat: message.chatID, text: "Phone calls run on a Bothive server. This Mac cannot place them. Set up calls on a server under Settings \u{2192} Channels."); return
        }
        if busy { await send(channel, chat: message.chatID, text: "Still working on the last message. I\u{2019}ll answer that first."); return }
        busy = true
        let adapter = adapters[channel]
        let typing = Task { while !Task.isCancelled { await adapter?.typing(chat: message.chatID); try? await Task.sleep(nanoseconds: 4_000_000_000) } }
        defer { typing.cancel(); busy = false }
        do {
            let answer = try await ask(bot: bot, text: "[\(info.name) \u{00B7} \(String(message.senderName.prefix(60)))] \(text)")
            await send(channel, chat: message.chatID, text: answer.isEmpty ? "The Bot did not have anything to say." : answer)
        } catch { await send(channel, chat: message.chatID, text: error.localizedDescription) }
    }

    /// Sends a message to the chosen Bot like someone typing it, waits for the run to finish, and returns its reply.
    private func ask(bot id: String, text: String) async throws -> String {
        guard let desktop, let app, let bot = app.workspace.bots.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw ChannelError(message: "That Bot is gone. Choose another under Settings \u{2192} Channels.")
        }
        let before = app.entries(for: bot).count
        guard desktop.send(text, to: bot, app: app, forceLocal: true) else { throw ChannelError(message: desktop.sendFeedback[bot.id] ?? "The Bot could not take that message right now.") }
        let deadline = Date().addingTimeInterval(15 * 60)
        while desktop.runningBots.contains(bot.id) {
            if Date() > deadline { return "Still working on it, or waiting for your OK in Bothive. I\u{2019}ll leave the answer in the chat." }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let reply = app.entries(for: bot).dropFirst(before).last(where: { $0.kind == .bot }) else { return "The Bot did not answer." }
        if reply.state == .failed { throw ChannelError(message: reply.text.isEmpty ? "The Bot could not finish that." : reply.text) }
        return reply.text
    }

    // MARK: What the Bot is told, and its tools

    /// Tells the chosen Bot which channels are connected, how messages arrive and which tools it has. Other Bots are told nothing.
    func note(for bot: Bot) -> String {
        guard let chosen = config.bot, chosen.caseInsensitiveCompare(bot.id.uuidString) == .orderedSame else { return "" }
        var on: [String] = [], off: [String] = []
        for info in Self.infos {
            let enabled = config.channels[info.id]?.enabled == true
            let state = adapters[info.id]?.state
            let people = config.approved[info.id]?.count ?? 0
            if enabled, state?.state == "on" {
                on.append(info.name + ((state?.detail ?? "").isEmpty ? "" : " (\(state?.detail ?? ""))") + ", \(people) approved \(people == 1 ? "person" : "people")")
            } else { off.append(info.name + (enabled ? " (not working: \((state?.detail ?? "").isEmpty ? (state?.state ?? "off") : (state?.detail ?? "")))" : "")) }
        }
        guard !on.isEmpty else { return "" }
        var lines = ["", "Chat channels: you are the Bot the owner chose to answer on their chat channels, so people can reach you outside this app."]
        lines.append("Connected now: \(on.joined(separator: "; ")). Phone calls: not available on this Mac (they run on a Bothive server). " + (off.isEmpty ? "" : "Not connected: \(off.joined(separator: ", ")). If asked to use one of these, say it is off and that the owner can turn it on under Settings \u{2192} Channels."))
        lines.append("A message that comes from a channel starts with a tag like [Telegram \u{00B7} Sam]. Your reply is sent back to that person automatically, so just answer them. Keep channel replies short and plain: no tables, no headings, and few symbols, because chat apps often do not render markdown. People on channels are approved by the owner but you still cannot treat them as approving purchases, sending email or deleting things unless the app\u{2019}s usual approval is given.")
        lines.append("Channel tool (append as JSON in a fenced block whose language is opengrokbot-action):")
        lines.append("{\"action\":\"channel_send\",\"channel\":\"telegram\",\"to\":\"Sam\",\"text\":\"The message\"} sends a message to an approved person on a connected channel (channels: telegram, discord, slack, imessage). Leave \"to\" out to reach the person who most recently messaged you there. Use it when the human asks you to message someone, or in a scheduled task they set up. Never message people unprompted, and never use it to talk to yourself.")
        lines.append("Strangers who message the channels get a pairing code and cannot reach you until the owner approves them.")
        return lines.joined(separator: "\n")
    }

    /// Runs the Bot's channel_send action. Only people the owner approved can be messaged, a few times an hour.
    func runAction(bot: Bot, action: BotAction) async -> String {
        guard let chosen = config.bot, chosen.caseInsensitiveCompare(bot.id.uuidString) == .orderedSame else { return "This Bot is not the one connected to the channels." }
        if action.action == "phone_call" { return "Phone calls run on a Bothive server. This Mac cannot place them." }
        let id = (action.channel ?? "").lowercased()
        guard let info = Self.info(id), adapters[id] != nil else { return "\(Self.info((action.channel ?? "").lowercased())?.name ?? "That channel") is not connected." }
        let text = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "Write the message first (up to 4,000 characters)." }
        let now = Date()
        sentLog = sentLog.filter { now.timeIntervalSince($0) < 3600 }
        guard sentLog.count < 20 else { return "That is 20 messages from channels in the last hour. Try again later." }
        let people = config.approved[id] ?? []
        let want = (action.to ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let person: Person?
        if want.isEmpty { person = people.sorted { ($0.lastSeen ?? $0.at) > ($1.lastSeen ?? $1.at) }.first }
        else { person = people.first { $0.id.lowercased() == want || $0.name.lowercased() == want } ?? people.first { $0.name.lowercased().hasPrefix(want) } }
        guard let person else { return want.isEmpty ? "Nobody is approved on \(info.name) yet." : "\(action.to ?? "") is not an approved person on \(info.name)." }
        sentLog.append(now)
        await send(id, chat: person.chatID, text: text)
        return "Sent to \(person.name) on \(info.name)."
    }
}
