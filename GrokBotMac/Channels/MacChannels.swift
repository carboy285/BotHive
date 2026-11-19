import AppKit
import Foundation

/// Chat channels on this Mac (10.1.2): one Bot you choose answers Telegram, Discord, Slack and iMessage (through Inkbox), and can reach out to you.
///
/// Safety first. A channel is a way to reach a Bot that can run tasks on this Mac, so nobody is answered until you approve them:
///  - A stranger gets a short code and nothing else. The code does nothing until you approve that person in Settings → Channels.
///    Codes last an hour, and each channel keeps at most 20 waiting.
///  - Approved people are rate limited, and a message is one Bot turn like any other (the Bot's own permission prompts still apply).
///  - In a Discord server or Slack channel the Bot only answers when it is @mentioned.
///  - The Bot reaches out first only to the person you mark as Me, a few times an hour.
/// Same rules as the Windows app and the Docker server (desktop-windows/app/channel-hub.cjs and channels-host.cjs).
/// SMS and Twilio calls need a public address, so they run on a Bothive server. Calls here go through Inkbox Voice AI.
@MainActor
final class MacChannels: ObservableObject {
    struct Person: Codable, Equatable {
        var id: String
        var name: String
        var chatID: String
        var at: Date
        var lastSeen: Date?
        /// A name you gave this person. The same name on two channels is one person to the Bot.
        var display: String? = nil
        /// You. Only you can answer approval prompts, and the Bot reaches out first only to you.
        var me: Bool? = nil
        var label: String { (display ?? "").isEmpty ? name : display ?? name }
    }
    struct ChannelConfig: Codable {
        var enabled = false
        var fields: [String: String] = [:]
    }
    struct Settings: Codable, Equatable {
        var fast = true
        var whenBusy = "steer"
        var reachOn: String? = nil
        var escalate = "call"
        var escalateMinutes = 10
        var quietStart = 22
        var quietEnd = 8
        /// "where": answer where the message came from (automatic turns text the owner); "always": text every reply to the owner too.
        var replies = "where"
        init() {}
        // Settings saved by an earlier build lack newer keys, so every key is optional when reading.
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            fast = try box.decodeIfPresent(Bool.self, forKey: .fast) ?? true
            whenBusy = try box.decodeIfPresent(String.self, forKey: .whenBusy) ?? "steer"
            reachOn = try box.decodeIfPresent(String.self, forKey: .reachOn)
            escalate = try box.decodeIfPresent(String.self, forKey: .escalate) ?? "call"
            escalateMinutes = try box.decodeIfPresent(Int.self, forKey: .escalateMinutes) ?? 10
            quietStart = try box.decodeIfPresent(Int.self, forKey: .quietStart) ?? 22
            quietEnd = try box.decodeIfPresent(Int.self, forKey: .quietEnd) ?? 8
            replies = try box.decodeIfPresent(String.self, forKey: .replies) ?? "where"
        }
    }
    /// A question the Bot asked you. Your next message on that channel is the answer.
    struct PendingAsk: Codable, Equatable {
        var botID: String
        var channel: String
        var senderID: String
        var chatID: String
        var question: String
        var askedAt: Date
        var urgent: Bool
        var escalated = false
    }
    struct Config: Codable {
        var bot: String?
        var channels: [String: ChannelConfig] = [:]
        var approved: [String: [Person]] = [:]
        var settings: Settings? = nil
        var pendingAsk: PendingAsk? = nil
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
    /// Who a message is from, as the Bot's turn sees it.
    struct Sender: Equatable {
        var channel: String
        var senderID: String
        var name: String
        var me = false
        var chatID: String
        var replyTo: String? = nil
    }
    private struct Batch {
        var from: Sender
        var texts: [String] = []
        var media: [ChannelMedia] = []
        var started = Date()
        var generation = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// A turn the app starts for the person (other Bots answered, a call ended): it waits its turn and never steers.
        var followUp = false
    }
    private final class BotState { var active = 0; var tail: Task<Void, Never>? }

    static let infos: [Info] = [
        Info(id: "telegram", name: "Telegram", limit: 4000, required: ["token"]),
        Info(id: "discord", name: "Discord", limit: 1900, required: ["token"]),
        Info(id: "slack", name: "Slack", limit: 3000, required: ["botToken", "appToken"]),
        Info(id: "imessage", name: "iMessage", limit: 4000, required: ["apiKey"]),
    ]
    private static let pairTTL: TimeInterval = 3600, maxPending = 20, window: TimeInterval = 600, maxPerWindow = 30, maxText = 4000, noticeGap: TimeInterval = 600
    private static let batchMax: TimeInterval = 2.5, maxMedia = 3

    @Published private(set) var config = Config()
    @Published private(set) var pending: [String: [Waiting]] = [:]
    weak var desktop: MacAppModel?
    weak var app: AppModel?
    /// How long messages are collected into one request. Tests set 0.
    var batchWindow: TimeInterval = 0.6
    /// How often unanswered urgent questions are checked.
    var askCheckSeconds: UInt64 = 30
    private var adapters: [String: any ChannelAdapter] = [:]
    private var recent: [String: [Date]] = [:]
    private var notices: [String: Date] = [:]
    private var sentLog: [Date] = []
    private var outreachLog: [Date] = []
    private var batches: [String: Batch] = [:]
    private var botStates: [String: BotState] = [:]
    private var turns: [UUID: Int] = [:]
    private var turnCounter = 0
    private var cancelled = Set<Int>()
    private var talking: [UUID: Sender] = [:]
    private var delegations: [UUID: (botID: UUID, from: Sender, at: Date)] = [:]
    private var mirrorLog: [Date] = []
    private var approvalAsks: [UUID: (channel: String, sender: String, at: Date)] = [:]
    private var voice: InkboxVoiceClient?
    private var voiceKey = ""
    private var voiceSyncTask: Task<Void, Never>?
    private var askLoop: Task<Void, Never>?
    private let store = KeychainSecretStore(service: "org.opengrokbot.mac.channels")

    static func isSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["token", "secret", "password", "key", "pin"].contains { lower.contains($0) }
    }
    static func info(_ id: String) -> Info? { infos.first { $0.id == id } }
    static let shared = MacChannels()

    /// Whether this is the Bot the owner chose to answer on channels.
    func isChosen(_ bot: Bot) -> Bool { config.bot?.caseInsensitiveCompare(bot.id.uuidString) == .orderedSame }
    /// Whether a request the channel Bot handed to other Bots is waiting to come back to a person.
    func isDelegated(_ root: UUID) -> Bool { delegations[root] != nil }
    /// Whether any channel is connected right now.
    var anyOn: Bool { Self.infos.contains { config.channels[$0.id]?.enabled == true && adapters[$0.id]?.state.state == "on" } }

    /// The Bothive tool server's channel_send: sends a message to an approved person and says what happened. Throws when nothing was sent.
    func runSend(botID: UUID, channel: String, to: String?, text: String) async throws -> String {
        guard let app, let bot = app.workspace.bots.first(where: { $0.id == botID }) else { throw ChannelError(message: "That Bot is gone.") }
        var body: [String: Any] = ["action": "channel_send", "channel": channel, "text": text]
        if let to { body["to"] = to }
        guard let data = try? JSONSerialization.data(withJSONObject: body), let action = try? JSONDecoder().decode(BotAction.self, from: data) else { throw ChannelError(message: "That message could not be read.") }
        let outcome = await runAction(bot: bot, action: action)
        if !outcome.hasPrefix("Sent to") { throw ChannelError(message: outcome) }
        return outcome
    }
    var settings: Settings { config.settings ?? Settings() }

    // MARK: Setup

    func attach(desktop: MacAppModel, app: AppModel) {
        self.desktop = desktop; self.app = app
        if let data = try? store.read(account: "config"), let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
        // Older setups had no owner: if exactly one person is approved, that is the owner.
        let everyone = config.approved.flatMap { channel, people in people.map { (channel, $0.id) } }
        if everyone.count == 1, owner(preferred: nil) == nil, let only = everyone.first, var list = config.approved[only.0], let index = list.firstIndex(where: { $0.id == only.1 }) {
            list[index].me = true; config.approved[only.0] = list; save()
        }
        for info in Self.infos where config.channels[info.id]?.enabled == true { start(info.id) }
        syncVoice()
        MacApproval.shared.onRoute = { [weak self] id, title, detail in Task { @MainActor in _ = await self?.routeApproval(id: id, title: title, detail: detail) } }
        askLoop?.cancel()
        askLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.askCheckSeconds ?? 30) * 1_000_000_000)
                await self?.checkAsks()
                await self?.checkDelegations()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { try? store.save(data, account: "config") }
    }

    private func botExists(_ id: String) -> Bool {
        app?.workspace.bots.contains { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame && $0.memberIDs == nil } ?? false
    }
    private func botFor(_ id: String) -> Bot? {
        app?.workspace.bots.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
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
                approved: (config.approved[info.id] ?? []).map { RemoteChannels.Approved(id: $0.id, name: $0.label, me: $0.me == true) },
                pending: live(info.id).map { RemoteChannels.Waiting(name: $0.name, code: $0.code) })
        }
        let bots = (app?.workspace.bots ?? []).filter { $0.memberIDs == nil }.map { RemoteChannels.BotChoice(id: $0.id.uuidString, name: $0.name) }
        var inkbox = RemoteChannels.Inkbox()
        inkbox.ready = voice != nil
        inkbox.state = voice?.state
        inkbox.ownerNumber = ownerNumber()
        inkbox.voices = (voice?.voices ?? []).map { RemoteChannels.Voice(id: $0.id, name: $0.name, available: $0.available) }
        inkbox.pendingAsk = config.pendingAsk.map { RemoteChannels.Question(question: $0.question) }
        return RemoteChannels(bot: config.bot, bots: bots, channels: channels, calls: RemoteChannels.Calls(ready: voice != nil, listening: false), settings: remoteSettings(), inkbox: inkbox)
    }

    private func remoteSettings() -> RemoteChannels.Settings {
        let s = settings
        return RemoteChannels.Settings(fast: s.fast, whenBusy: s.whenBusy, replies: s.replies, reachOn: s.reachOn, escalate: s.escalate, escalateMinutes: s.escalateMinutes, quietStart: s.quietStart, quietEnd: s.quietEnd)
    }

    /// The same commands the Windows app and Docker server take, so one screen manages either.
    func execute(_ action: String, channel: String?, text: String?, fields: [String: String]?) async -> String? {
        do {
            switch action {
            case "channels_set_bot": try setBot(text ?? "")
            case "channels_configure": try await configure(channel, fields ?? [:])
            case "channels_enable": try await setEnabled(channel, on: text == "on")
            case "channels_approve": try approve(channel, code: text ?? "", me: fields?["me"].map { $0 == "true" })
            case "channels_remove": remove(channel, id: text ?? "")
            case "channels_set_settings": try setSettings(fields ?? [:])
            case "channels_set_person": try setPerson(channel, id: text ?? "", fields: fields ?? [:])
            case "channels_test_call": _ = try await callOwner(from: nil)
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
        save(); objectWillChange.send(); syncVoice()
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
        syncVoice()
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
        syncVoice()
        objectWillChange.send()
    }

    /// The few switches on the Channels screen.
    func setSettings(_ fields: [String: String]) throws {
        var next = settings
        if let value = fields["fast"] { next.fast = value == "true" }
        if let value = fields["whenBusy"] { guard ["steer", "queue"].contains(value) else { throw ChannelError(message: "Choose Steer or Queue.") }; next.whenBusy = value }
        if let value = fields["replies"] { guard ["where", "always"].contains(value) else { throw ChannelError(message: "Choose where replies go.") }; next.replies = value }
        if let value = fields["reachOn"] { next.reachOn = Self.info(value) == nil ? nil : value }
        if let value = fields["escalate"] { guard ["call", "text", "none"].contains(value) else { throw ChannelError(message: "Choose call, text or nothing.") }; next.escalate = value }
        if let value = fields["escalateMinutes"], let number = Int(value) { next.escalateMinutes = min(120, max(1, number)) }
        if let value = fields["quietStart"], let number = Int(value) { next.quietStart = min(23, max(0, number)) }
        if let value = fields["quietEnd"], let number = Int(value) { next.quietEnd = min(23, max(0, number)) }
        config.settings = next; save(); objectWillChange.send()
    }

    /// Rename an approved person, or mark them as you.
    func setPerson(_ channel: String?, id: String, fields: [String: String]) throws {
        guard let channel, var list = config.approved[channel], let index = list.firstIndex(where: { $0.id == id }) else { throw ChannelError(message: "That person is not approved.") }
        if let name = fields["name"] {
            let clean = String(name.unicodeScalars.map { $0.value < 32 ? " " : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            list[index].display = clean.isEmpty ? nil : clean
        }
        if let me = fields["me"] { list[index].me = me == "true" }
        config.approved[channel] = list; save(); objectWillChange.send(); syncVoice()
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
        refreshListening()
        Task {
            do { try await adapter.start() } catch { adapter.state = RemoteChannels.State(state: "error", detail: error.localizedDescription) }
            self.objectWillChange.send()
        }
    }

    private func stop(_ id: String) { adapters[id]?.stop(); adapters[id] = nil; refreshListening() }

    /// While a channel is on, macOS must not nap the app: App Nap would stretch the twice-a-second check to many seconds when Bothive is
    /// in the background. This also keeps the Mac from idle-sleeping, so messages are answered while you are away from it.
    private var listening: NSObjectProtocol?
    private func refreshListening() {
        if !adapters.isEmpty, listening == nil {
            listening = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Bothive is listening for chat messages")
        } else if adapters.isEmpty, let activity = listening {
            ProcessInfo.processInfo.endActivity(activity); listening = nil
        }
    }

    /// Tests replace the Bot turn and watch for stops.
    var askOverride: ((String, Sender, String, [ChannelMedia], Bool) async throws -> String?)?
    var onStop: ((UUID) -> Void)?
    /// Whether Bothive is in front. Approval prompts are only sent to the chat when it is not, or when a chat turn asked for them.
    var appIsActive: () -> Bool = { NSApp?.isActive == true }

    /// Used by tests to put a fake adapter in place.
    func install(_ adapter: any ChannelAdapter, for id: String) { adapters[id] = adapter }
    func configureForTesting(_ value: Config) { config = value }

    // MARK: People

    private func live(_ id: String) -> [Waiting] { (pending[id] ?? []).filter { Date().timeIntervalSince($0.at) < Self.pairTTL } }

    private func approve(_ id: String?, code: String, me requested: Bool? = nil) throws {
        // The first person approved is almost always the owner, so they are Me unless someone already is.
        let me = requested ?? (owner(preferred: nil) == nil)
        guard let id, Self.info(id) != nil else { throw ChannelError(message: "Unknown channel.") }
        guard let entry = live(id).first(where: { $0.code == code.trimmingCharacters(in: .whitespaces) }) else { throw ChannelError(message: "That code is not waiting. Ask them to message the Bot again to get a new one.") }
        pending[id] = live(id).filter { $0.code != entry.code }
        var list = config.approved[id] ?? []
        if let index = list.firstIndex(where: { $0.id == entry.senderID }) { if me { list[index].me = true } }
        else { list.append(Person(id: entry.senderID, name: entry.name, chatID: entry.chatID, at: Date(), me: me ? true : nil)) }
        config.approved[id] = list; save()
        syncVoice()
        Task { await self.send(id, chat: entry.chatID, text: "You\u{2019}re approved. Send a message and the Bot will answer.") }
    }

    /// Used by tests to approve someone without a pairing code.
    func approveForTesting(_ channel: String, person: Person) { config.approved[channel, default: []].append(person) }

    private func remove(_ id: String?, id person: String) {
        guard let id else { return }
        config.approved[id] = (config.approved[id] ?? []).filter { $0.id != person }
        pending[id] = live(id).filter { $0.senderID != person }
        save(); objectWillChange.send()
    }

    private func isApproved(_ channel: String, _ sender: String) -> Bool { (config.approved[channel] ?? []).contains { $0.id == sender } }

    /// The person marked Me, preferring a channel. Unprompted messages and calls go only to them.
    func owner(preferred: String?) -> (channel: String, person: Person)? {
        for channel in [preferred].compactMap({ $0 }) + Self.infos.map(\.id) {
            if let person = (config.approved[channel] ?? []).first(where: { $0.me == true && !$0.chatID.isEmpty }) { return (channel, person) }
        }
        return nil
    }

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
        _ = try? await sendOrThrow(channel, chat: chat, text: text)
    }
    private func sendOrThrow(_ channel: String, chat: String, text: String) async throws {
        guard let adapter = adapters[channel], let info = Self.info(channel) else { throw ChannelError(message: "That channel is not connected.") }
        for piece in Self.chunks(text, limit: info.limit) { try await adapter.send(chat: chat, text: piece) }
    }

    // MARK: Messages

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
    private static let callWords = regex(#"^\s*(?:/call|(?:hey\s+)?(?:please\s+)?(?:can\s+you\s+|could\s+you\s+)?(?:give\s+me\s+a\s+)?(?:call|phone|ring)(?:\s+me)?(?:\s+now|\s+please)?[.!?]*)\s*$"#)
    private static let stopWords = regex(#"^\s*(?:/stop|stop|cancel|abort|never\s*mind|nevermind)(?:\s+(?:it|that|please))?[.!]*\s*$"#)
    private static let yesWords = regex(#"^\s*(?:yes|y|yep|yeah|approve|approved|ok|okay|go ahead|do it|sure)[.!]*\s*$"#)
    private static let noWords = regex(#"^\s*(?:no|n|nope|deny|denied|don'?t|do not)[.!]*\s*$"#)
    static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool { expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    static func isCallRequest(_ text: String) -> Bool { matches(callWords, text) }
    static func isStopRequest(_ text: String) -> Bool { matches(stopWords, text) }

    func inbound(_ channel: String, _ message: ChannelMessage) async {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = Array(message.media.prefix(Self.maxMedia))
        guard let info = Self.info(channel), !text.isEmpty || !media.isEmpty, let botID = config.bot, botExists(botID) else { return }
        if !isApproved(channel, message.senderID) {
            // Strangers get a code once in a while and nothing else. Nothing they write (or send) reaches the Bot.
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
        // Approved: show it was read right away, before anything slow happens.
        if let adapter = adapters[channel] { Task { await adapter.acknowledge(message); await adapter.typing(chat: message.chatID) } }
        let now = Date(), key = channel + ":" + message.senderID
        var times = (recent[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        if times.count >= Self.maxPerWindow {
            if times.count == Self.maxPerWindow { times.append(now); recent[key] = times; await send(channel, chat: message.chatID, text: "That is a lot of messages. Give it a few minutes.") }
            return
        }
        times.append(now); recent[key] = times
        var person: Person?
        if var list = config.approved[channel], let index = list.firstIndex(where: { $0.id == message.senderID }) {
            list[index].lastSeen = now; list[index].chatID = message.chatID; config.approved[channel] = list; person = list[index]
        }
        // The owner can answer an approval prompt that was sent to the chat with a plain yes or no.
        if person?.me == true, media.isEmpty {
            let verdict: Bool? = Self.matches(Self.yesWords, text) ? true : (Self.matches(Self.noWords, text) ? false : nil)
            if let verdict, answerApproval(channel: channel, sender: message.senderID, yes: verdict) {
                await send(channel, chat: message.chatID, text: verdict ? "Approved." : "Denied."); return
            }
        }
        if text.count > Self.maxText { await send(channel, chat: message.chatID, text: "That message is too long (the limit is \(Self.maxText) characters)."); return }
        if media.isEmpty, Self.isStopRequest(text) {
            if let id = UUID(uuidString: botID), (botStates[botID]?.active ?? 0) > 0 { stopTurn(id); await send(channel, chat: message.chatID, text: "Stopped.") }
            else { await send(channel, chat: message.chatID, text: "Nothing is running right now.") }
            return
        }
        if media.isEmpty, Self.isCallRequest(text) {
            do { await send(channel, chat: message.chatID, text: try await callOwner(from: Sender(channel: channel, senderID: message.senderID, name: message.senderName, me: person?.me == true, chatID: message.chatID))) }
            catch { await send(channel, chat: message.chatID, text: error.localizedDescription) }
            return
        }
        var from = Sender(channel: channel, senderID: message.senderID, name: person?.label ?? message.senderName, me: person?.me == true, chatID: message.chatID)
        if let ask = config.pendingAsk, person?.me == true, ask.channel == channel, ask.senderID == message.senderID {
            from.replyTo = ask.question; config.pendingAsk = nil; save()
        }
        _ = info
        await collect(key: key, from: from, text: text, media: media)
    }

    /// Messages from one person within a short window become one request, so a photo and "add these to my reminders" arrive together.
    private func collect(key: String, from: Sender, text: String, media: [ChannelMedia]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var batch = batches[key] ?? Batch(from: from)
            if !text.isEmpty { batch.texts.append(text) }
            batch.media += media; batch.waiters.append(continuation); batch.generation += 1
            batches[key] = batch
            if batchWindow <= 0 { flush(key); return }
            let generation = batch.generation
            let delay = min(batchWindow, max(0, Self.batchMax - Date().timeIntervalSince(batch.started)))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.flushIfCurrent(key, generation)
            }
        }
    }
    private func flushIfCurrent(_ key: String, _ generation: Int) { if batches[key]?.generation == generation { flush(key) } }
    private func flush(_ key: String) {
        guard let batch = batches.removeValue(forKey: key) else { return }
        Task { [weak self] in
            await self?.dispatch(batch)
            for waiter in batch.waiters { waiter.resume() }
        }
    }

    /// Runs one request on the Bot. If the Bot is already working, Steer stops that turn and carries on with this one; Queue waits for it.
    private func dispatch(_ batch: Batch) async {
        guard let botID = config.bot, botExists(botID), let id = UUID(uuidString: botID) else { return }
        let from = batch.from
        let text = String(batch.texts.joined(separator: "\n").prefix(Self.maxText * 2)), media = Array(batch.media.prefix(Self.maxMedia))
        let state = botStates[botID] ?? BotState(); botStates[botID] = state
        let steer = !batch.followUp && state.active > 0 && settings.whenBusy != "queue"
        state.active += 1
        if steer { stopTurn(id) }
        let previous = state.tail
        let turn = Task { [weak self] in
            await previous?.value
            await self?.runTurn(botID, from: from, text: text, media: media, steer: steer, followUp: batch.followUp)
        }
        state.tail = turn
        await turn.value
        state.active -= 1
    }

    private func runTurn(_ botID: String, from: Sender, text: String, media: [ChannelMedia], steer: Bool, followUp: Bool = false) async {
        let adapter = adapters[from.channel]
        let typing = Task { while !Task.isCancelled { await adapter?.typing(chat: from.chatID); try? await Task.sleep(nanoseconds: 4_000_000_000) } }
        defer { typing.cancel() }
        do {
            let reply: String?
            if let askOverride { reply = try await askOverride(botID, from, text, media, steer) } else { reply = try await ask(bot: botID, from: from, text: text, media: media, steer: steer, fullModel: followUp, progress: { [weak self] part in await self?.send(from.channel, chat: from.chatID, text: part) }) }
            guard let answer = reply else { return }
            await send(from.channel, chat: from.chatID, text: answer.isEmpty ? "The Bot did not have anything to say." : answer)
        } catch { await send(from.channel, chat: from.chatID, text: error.localizedDescription) }
    }

    static let steerNote = MacAppModel.steerNote

    /// Stops the turn that is running for this Bot. Its answer is discarded.
    func stopTurn(_ botID: UUID) {
        if let token = turns[botID] { cancelled.insert(token) }
        onStop?(botID)
        desktop?.stop(botID: botID)
    }

    /// Sends a message to the chosen Bot like someone typing it, waits for the run to finish, and returns its reply (nil if the turn was stopped).
    func ask(bot id: String, from: Sender, text: String, media: [ChannelMedia] = [], steer: Bool = false, fullModel: Bool = false, progress: ((String) async -> Void)? = nil) async throws -> String? {
        guard let desktop, let app, let bot = botFor(id) else { throw ChannelError(message: "That Bot is gone. Choose another under Settings \u{2192} Channels.") }
        var body = text
        if !media.isEmpty {
            let saved = await ChannelMediaStore.save(media, into: desktop.workingDirectory(for: bot))
            let words = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if saved.names.isEmpty && words.isEmpty { return "I could not use that: \(saved.problems.first ?? "nothing readable came through")." }
            body = MacAppModel.attachmentMessage(base: words.isEmpty ? "(photo)" : words, names: saved.names)
            if !saved.problems.isEmpty { body += "\n(Also: \(saved.problems.joined(separator: "; ")).)" }
        }
        if let replyTo = from.replyTo { body = "(This answers the question you asked them: \u{201C}\(replyTo.prefix(300))\u{201D}. Carry on with what you were doing.)\n" + body }
        let channelName = Self.info(from.channel)?.name ?? from.channel
        body = "[\(channelName) \u{00B7} \(String(from.name.prefix(60)))\(from.me ? " \u{00B7} the owner" : "")] " + body
        if steer { body += Self.steerNote }
        let before = app.entries(for: bot).count
        turnCounter += 1; let token = turnCounter; turns[bot.id] = token
        if from.channel != "phone" { talking[bot.id] = from }
        guard desktop.send(body, to: bot, app: app, forceLocal: true, channelTurn: settings.fast && !fullModel && from.channel != "phone", fromChannel: true) else {
            talking[bot.id] = nil
            throw ChannelError(message: desktop.sendFeedback[bot.id] ?? "The Bot could not take that message right now.")
        }
        let deadline = Date().addingTimeInterval(45 * 60)
        // Wait for the whole chain: a turn that used a tool (Reminders, the browser) is followed by another turn with the result.
        // Replies that arrive along the way ("I'll check now") are sent at once, so the person is never left waiting on silence.
        var sent = Set<UUID>()
        while desktop.isWorking(bot.id) {
            if Date() > deadline { talking[bot.id] = nil; return "Still working on it, or waiting for your OK in Bothive. I\u{2019}ll leave the answer in the chat." }
            let finished = app.entries(for: bot).dropFirst(before).filter { $0.kind == .bot && $0.state == .complete && !$0.text.isEmpty && !sent.contains($0.id) }
            for entry in finished { sent.insert(entry.id); await progress?(entry.text) }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if talking[bot.id] == from { talking[bot.id] = nil }
        if cancelled.remove(token) != nil { return nil }
        guard let reply = app.entries(for: bot).dropFirst(before).last(where: { $0.kind == .bot }) else { return "The Bot did not answer." }
        if reply.state == .failed { throw ChannelError(message: reply.text.isEmpty ? "The Bot could not finish that." : reply.text) }
        // The Bot handed part of this to other Bots: when they answer, it gets a follow-up turn so the person hears back.
        if from.channel != "phone", (app.workspace.teamMessages ?? []).contains(where: { $0.rootID == reply.id && $0.from == bot.id }) {
            delegations[reply.id] = (bot.id, from, Date())
        }
        if sent.contains(reply.id) { return nil } // already sent while the Bot was still working
        return reply.text
    }

    // MARK: Phone calls through Inkbox Voice AI

    func ownerNumber() -> String {
        if let mine = owner(preferred: "imessage"), mine.channel == "imessage", InkboxVoiceClient.isPhoneNumber(mine.person.id) { return mine.person.id }
        let typed = config.channels["imessage"]?.fields["ownerNumber"] ?? ""
        return InkboxVoiceClient.isPhoneNumber(typed) ? typed : ""
    }

    func inQuietHours(_ date: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: date), a = settings.quietStart, b = settings.quietEnd
        if a == b { return false }
        return a < b ? (hour >= a && hour < b) : (hour >= a || hour < b)
    }

    /// Starts, restarts or stops the Inkbox voice client to match the iMessage settings.
    private func syncVoice() {
        let imessage = config.channels["imessage"]
        let key = (imessage?.enabled == true && !(imessage?.fields["apiKey"] ?? "").isEmpty) ? [imessage?.fields["apiKey"] ?? "", imessage?.fields["voice"] ?? "", imessage?.fields["voiceLine"] ?? ""].joined(separator: "|") : ""
        guard key != voiceKey else { return }
        voice?.stop(); voice = nil; voiceKey = key
        guard !key.isEmpty, let fields = imessage?.fields else { return }
        let client = InkboxVoiceClient(apiKey: fields["apiKey"] ?? "", voice: fields["voice"] ?? "", line: fields["voiceLine"] ?? "")
        client.context = { [weak self] in self?.voiceContext() ?? InkboxVoiceClient.Context() }
        client.onCall = { [weak self] call in await self?.importCall(call) }
        voice = client
        Task { do { try await client.start() } catch { self.objectWillChange.send() }; self.objectWillChange.send() }
    }

    private func voiceContext() -> InkboxVoiceClient.Context {
        guard let id = config.bot, let bot = botFor(id) else { return InkboxVoiceClient.Context() }
        let person = owner(preferred: "imessage")?.person
        return InkboxVoiceClient.Context(botName: bot.name, purpose: bot.purpose, summary: bot.summary ?? "", memory: bot.memory ?? [], ownerName: person?.label ?? "")
    }

    /// Tell the voice agent about new memory. Waits a little so a burst of changes is one update.
    func voiceInstructionsChanged() {
        guard let voice else { return }
        voiceSyncTask?.cancel()
        voiceSyncTask = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if !Task.isCancelled { _ = try? await voice.syncInstructions() } }
    }

    /// "Call me" from a chat, or the Call me now button.
    func callOwner(from: Sender?) async throws -> String {
        guard let voice else { throw ChannelError(message: "Phone calls on this Mac go through Inkbox. Turn on iMessage (through Inkbox) first. Twilio calls run on a Bothive server.") }
        let number = ownerNumber()
        if let from, !from.me, !(from.channel == "imessage" && from.senderID == number) { throw ChannelError(message: "Only the owner can ask for a call.") }
        guard !number.isEmpty else { throw ChannelError(message: "Add your own phone number under Settings \u{2192} Channels \u{2192} iMessage, or mark yourself as Me.") }
        try await voice.placeCall(to: number, reason: "The owner asked you to phone them. Greet them by name, say you are ready, and ask how you can help.")
        return "Calling you now."
    }

    /// A finished call: its transcript goes into the Bot's chat and memory, and whatever it needs done is handed to the Bot.
    /// A finished call: its transcript goes into the Bot's chat, and the Bot gets a turn with all of it, so it knows what was said and carries on.
    func importCall(_ call: InkboxVoiceClient.Call) async {
        guard let app, let id = config.bot, let bot = botFor(id) else { return }
        let person = owner(preferred: "imessage")?.person
        let name = person?.label ?? (call.number.isEmpty ? "someone" : call.number)
        let lines = call.transcript.map { "\($0.fromPerson ? name : "You"): \($0.text)" }.joined(separator: "\n")
        let minutes = call.seconds >= 60 ? "\(Int((Double(call.seconds) / 60).rounded())) min" : "\(call.seconds) s"
        let reason = call.reason.isEmpty ? "" : " (\(call.reason.prefix(200)))"
        let outcome = call.outcome.isEmpty || call.status == "completed" ? "" : ", " + call.outcome
        let who = call.direction == "outbound" ? "You phoned them" : "They phoned you"
        let what = "\(who)\(reason), \(minutes)\(outcome)"
        let transcript = !lines.isEmpty ? String(lines.prefix(6000)) : (call.transcriptError.isEmpty ? "(no speech was recorded)" : "(the transcript could not be downloaded: \(call.transcriptError))")
        app.addNote("[Phone call \u{00B7} \(name)] \(what).\n\(transcript)", to: bot)
        let spoke = call.transcript.filter(\.fromPerson).map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let todo = call.items.map { "- " + $0.action + ($0.details.isEmpty ? "" : ": " + $0.details) }.joined(separator: "\n")
        var text = ""
        if let ask = config.pendingAsk, !spoke.isEmpty, !call.number.isEmpty, call.number == ownerNumber() {
            config.pendingAsk = nil; save()
            text = "(This call answers the question you asked them: \u{201C}\(ask.question.prefix(300))\u{201D}.)\n"
        }
        text += "(Automatic follow-up after a phone call, not a new text from them.) You just finished a phone call with \(name): \(what). Inkbox\u{2019}s voice assistant spoke for you on the call and could not use your tools. The full transcript:\n\(transcript)\n"
        if !todo.isEmpty { text += "Left to do from the call:\n\(todo)\n" }
        text += "Keep what matters from this call in mind from now on. Carry on with anything that is left to do (anything that sends, buys, posts or deletes still needs the human\u{2019}s OK), then reply with a one-line recap for them."
        if let target = owner(preferred: "imessage") ?? owner(preferred: nil), adapters[target.channel] != nil {
            await followUp(Sender(channel: target.channel, senderID: target.person.id, name: name, me: true, chatID: target.person.chatID), text: text)
        } else {
            _ = try? await ask(bot: id, from: Sender(channel: "phone", senderID: call.number, name: name, me: true, chatID: ""), text: text)
        }
        // Refresh the summary now, so the next call's voice assistant knows what was said on this one.
        _ = await desktop?.memory.runPass(bot)
    }

    /// A turn the app starts for the person. It waits for anything running and never steers it.
    func followUp(_ from: Sender, text: String) async {
        await dispatch(Batch(from: from, texts: [text], followUp: true))
    }

    /// Other Bots finished the work the channel Bot handed them: give it a follow-up turn with their answers so the person hears back.
    func checkDelegations() async {
        guard let app else { return }
        for (root, job) in delegations {
            if Date().timeIntervalSince(job.at) > 45 * 60 { delegations[root] = nil; continue }
            let messages = (app.workspace.teamMessages ?? []).filter { $0.rootID == root }
            if messages.contains(where: { $0.status == .queued || $0.status == .running }) { continue }
            delegations[root] = nil
            let since = job.at.addingTimeInterval(-1)
            let answers = app.workspace.entries.filter { $0.botID == job.botID && $0.kind == .bot && $0.senderBotID != nil && $0.date >= since }
                .map { "\($0.senderName ?? "A Bot"): \($0.text.prefix(3000))" }
            let failed = messages.filter { $0.from == job.botID && $0.status != .complete }.map { message in app.workspace.bots.first { $0.id == message.to }?.name ?? "A Bot" }
            guard !answers.isEmpty || !failed.isEmpty else { continue }
            var text = "(Automatic follow-up, not a new message from them.) The Bots you asked have finished.\n" + answers.joined(separator: "\n\n")
            if !failed.isEmpty { text += "\n\(failed.joined(separator: ", ")) could not finish." }
            text += "\nUse this to finish their request and reply to them."
            Task { await self.followUp(job.from, text: text) }
        }
    }

    /// A reply the Bot gave outside a chat channel. Depending on "Where replies go", it is also texted to the owner. Returns whether it was sent.
    @discardableResult
    func afterReply(bot: Bot, text: String, origin: String) async -> Bool {
        await checkDelegations()
        guard let chosen = config.bot, chosen.caseInsensitiveCompare(bot.id.uuidString) == .orderedSame, origin != "channel", origin != "delivery" else { return false }
        if origin == "app", settings.replies != "always" { return false }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let target = owner(preferred: settings.reachOn), adapters[target.channel] != nil else { return false }
        mirrorLog = mirrorLog.filter { Date().timeIntervalSince($0) < 3600 }
        guard mirrorLog.count < 30 else { return false }
        mirrorLog.append(Date())
        do { try await sendOrThrow(target.channel, chat: target.person.chatID, text: String(clean.prefix(6000))); return true } catch { return false }
    }

    // MARK: The Bot asks the owner something, or needs an OK

    /// Sends an approval prompt to the owner's chat. The window prompt stays; the first answer wins.
    @discardableResult
    func routeApproval(id: UUID, title: String, detail: String) async -> Bool {
        guard let target = owner(preferred: settings.reachOn), adapters[target.channel] != nil else { return false }
        guard !appIsActive() || !talking.isEmpty else { return false }
        let text = "Needs your OK: \(title)" + (detail.isEmpty ? "" : " \u{2014} " + String(detail.prefix(600))) + "\nReply yes or no."
        do { try await sendOrThrow(target.channel, chat: target.person.chatID, text: text) } catch { return false }
        approvalAsks[id] = (target.channel, target.person.id, Date())
        return true
    }

    func answerApproval(channel: String, sender: String, yes: Bool) -> Bool {
        for (id, ask) in approvalAsks {
            if Date().timeIntervalSince(ask.at) > 3600 { approvalAsks[id] = nil; continue }
            if ask.channel == channel, ask.sender == sender { approvalAsks[id] = nil; return MacApproval.shared.respondFromPhone(id: id, approved: yes) }
        }
        return false
    }

    /// Text that is safe as the first message of a conversation: Inkbox wants under 160 characters, no links and no phone numbers until the person replies.
    static func openingText(_ text: String) -> String {
        var clean = text
        for pattern in [#"https?://\S+|www\.\S+"#, #"\+?\d[\d\s().-]{7,}\d"#] { clean = clean.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        clean = clean.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if clean.count <= 159 { return clean }
        var cut = String(clean.prefix(156))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut + "\u{2026}"
    }

    /// Runs the Bot's ask_owner action: texts the person marked Me, notes the question, and waits for the answer.
    func askOwner(bot: Bot, action: BotAction) async -> String {
        let question = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 1500 else { return "Write the question first (up to 1,500 characters)." }
        guard let target = owner(preferred: settings.reachOn) else { return "Nobody is marked Me yet. Open Settings \u{2192} Channels and tick Me next to your own name, so the Bot knows who to reach out to." }
        let now = Date()
        outreachLog = outreachLog.filter { now.timeIntervalSince($0) < 86_400 }
        guard outreachLog.count < 20, outreachLog.filter({ now.timeIntervalSince($0) < 3600 }).count < 5 else { return "That is as many messages to the owner as allowed for now. Try again later." }
        let label = target.person.label, channelName = Self.info(target.channel)?.name ?? target.channel
        var ask = PendingAsk(botID: bot.id.uuidString, channel: target.channel, senderID: target.person.id, chatID: target.person.chatID, question: question, askedAt: now, urgent: action.urgent == true)
        if let here = talking[bot.id], here.channel == target.channel, here.senderID == target.person.id {
            config.pendingAsk = ask; save()
            return "Waiting for \(label)\u{2019}s answer."
        }
        var how = "text"
        do {
            guard adapters[target.channel] != nil else { throw ChannelError(message: "\(channelName) is not connected.") }
            let fresh = target.channel == "imessage" && (target.person.lastSeen.map { now.timeIntervalSince($0) > 12 * 3600 } ?? true)
            try await sendOrThrow(target.channel, chat: ask.chatID, text: fresh ? Self.openingText(question) : question)
        } catch {
            let number = ownerNumber()
            if ask.urgent, let voice, !number.isEmpty, !inQuietHours() {
                do { try await voice.placeCall(to: number, reason: "Ask the owner this and record the answer: " + question); how = "call" }
                catch { return "Could not reach \(label): \(error.localizedDescription)" }
            } else {
                return "Could not reach \(label) on \(channelName)\(target.channel == "imessage" ? " (they need to text the Bot once first, or Inkbox\u{2019}s link has lapsed)" : ""): \(error.localizedDescription)"
            }
        }
        outreachLog.append(now)
        ask.escalated = false; config.pendingAsk = ask; save()
        return how == "call" ? "Phoned \(label) to ask. Their answer comes back to you after the call." : "Asked \(label) on \(channelName). Their reply comes back to you."
    }

    /// Runs every half minute: an urgent question nobody answered becomes a call, outside quiet hours, or a second text.
    func checkAsks(now: Date = Date()) async {
        guard var ask = config.pendingAsk else { return }
        if now.timeIntervalSince(ask.askedAt) > 86_400 { config.pendingAsk = nil; save(); return }
        let s = settings
        guard ask.urgent, !ask.escalated, s.escalate != "none", now.timeIntervalSince(ask.askedAt) >= Double(s.escalateMinutes) * 60 else { return }
        ask.escalated = true; config.pendingAsk = ask; save()
        let number = ownerNumber()
        if s.escalate == "call", let voice, !number.isEmpty, !inQuietHours(now) {
            if (try? await voice.placeCall(to: number, reason: "Ask the owner this and record the answer: " + ask.question)) != nil { return }
        }
        await send(ask.channel, chat: ask.chatID, text: String("Still need your answer: \(ask.question)".prefix(1500)))
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
        let calls = voice != nil
        guard !on.isEmpty || calls else { return "" }
        var lines = ["", "Chat channels: you are the Bot the owner chose to answer on their chat channels, so people can reach you outside this app."]
        lines.append("Connected now: \(on.isEmpty ? "none" : on.joined(separator: "; ")). Phone calls: \(calls ? "ready (you can phone the owner, and the owner can call you)" : "not set up (Twilio calls run on a Bothive server; here, calls go through Inkbox)"). " + (off.isEmpty ? "" : "Not connected: \(off.joined(separator: ", ")). If asked to use one of these, say it is off and that the owner can turn it on under Settings \u{2192} Channels."))
        lines.append("A message that comes from a channel starts with a tag like [Telegram \u{00B7} Sam]. Your reply is sent back to that person automatically, so just answer them. Keep channel replies short and plain: no tables, no headings, and few symbols, because chat apps often do not render markdown. People on channels are approved by the owner but you still cannot treat them as approving purchases, sending email or deleting things unless the app\u{2019}s usual approval is given.")
        lines.append("Channel tools (append each as JSON in a fenced block whose language is opengrokbot-action):")
        lines.append("{\"action\":\"channel_send\",\"channel\":\"telegram\",\"to\":\"Sam\",\"text\":\"The message\"} sends a message to an approved person on a connected channel (channels: telegram, discord, slack, imessage). Leave \"to\" out to reach the person who most recently messaged you there. Use it when the human asks you to message someone, or in a scheduled task they set up. You may also message the owner (the person marked Me) on your own when they would want to know: a task you finished, a result they are waiting for, a reminder they asked for. Never message anyone else unprompted, and never use it to talk to yourself.")
        if calls { lines.append("{\"action\":\"phone_call\",\"text\":\"What the call is about\"} phones the owner\u{2019}s number and then talks with them. Use it only when the human asks for a call or has told you to call for something urgent. At most five calls an hour. A phone call is answered by a separate fast voice assistant that knows your name and notes; the call transcript comes back into your chat afterwards.") }
        if owner(preferred: nil) != nil { lines.append("{\"action\":\"ask_owner\",\"text\":\"The question\",\"urgent\":false} texts the owner (the person marked Me) when you need a decision or a missing detail and nobody is chatting with you: use it instead of guessing or stopping silently, then end your turn. Their next message on that channel comes back to you tagged as the answer. Set urgent true only when waiting would cause harm; then the app calls them if they do not answer. Do not use it just to report progress.") }
        lines.append("Strangers who message the channels get a pairing code and cannot reach you until the owner approves them.")
        return lines.joined(separator: "\n")
    }

    /// Runs the Bot's channel actions. Only people the owner approved can be messaged, a few times an hour.
    func runAction(bot: Bot, action: BotAction) async -> String {
        guard let chosen = config.bot, chosen.caseInsensitiveCompare(bot.id.uuidString) == .orderedSame else { return "This Bot is not the one connected to the channels." }
        if action.action == "ask_owner" { return await askOwner(bot: bot, action: action) }
        if action.action == "phone_call" {
            guard let voice else { return "Phone calls on this Mac go through Inkbox. Turn on iMessage (through Inkbox) under Settings \u{2192} Channels first." }
            let number = ownerNumber()
            guard !number.isEmpty else { return "Add your own phone number under Settings \u{2192} Channels \u{2192} iMessage, or mark yourself as Me." }
            let reason = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do { try await voice.placeCall(to: number, reason: reason.isEmpty ? "Phone the owner and ask how you can help." : reason); return "Calling the owner now." }
            catch { return error.localizedDescription }
        }
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
        else { person = people.first { $0.id.lowercased() == want || $0.label.lowercased() == want } ?? people.first { $0.label.lowercased().hasPrefix(want) } }
        guard let person else { return want.isEmpty ? "Nobody is approved on \(info.name) yet." : "\(action.to ?? "") is not an approved person on \(info.name)." }
        sentLog.append(now)
        await send(id, chat: person.chatID, text: text)
        return "Sent to \(person.label) on \(info.name)."
    }
}
