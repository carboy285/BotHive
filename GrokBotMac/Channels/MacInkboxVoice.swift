import Foundation

/// Phone calls through Inkbox Voice AI (10.1.2). Inkbox answers and places the calls with its own voice model, so it feels instant and needs
/// no public address. Bothive feeds it the Bot (name, style, a summary and notes) as the call instructions, places calls with the reason as
/// its brief, and reads finished calls back over REST so the transcript lands in the Bot's chat and memory. This is Inkbox's voice model,
/// not the Bot's own CLI, so it cannot run the Bot's tools during a call. Same behavior as desktop-windows/app/channel-inkbox-voice.cjs.
@MainActor
final class InkboxVoiceClient {
    struct Line: Equatable { var fromPerson: Bool; var text: String }
    struct Item: Equatable { var action: String; var details: String }
    struct Call: Equatable {
        var id: String, direction: String, number: String, reason: String, status: String, outcome: String
        var seconds: Int
        var transcript: [Line]
        var items: [Item]
    }
    struct VoiceChoice: Equatable { var id: String; var name: String; var available: Bool }
    struct Context { var botName = "the assistant", purpose = "", summary = "", memory: [String] = [], ownerName = "" }

    static let instructionsMax = 8000, reasonMax = 2000, callsPerHour = 5
    private static let base = "https://inkbox.ai/api/v1/phone"
    private static let phone = try! NSRegularExpression(pattern: #"^\+[1-9]\d{6,14}$"#)

    let apiKey: String
    var voice: String
    var line: String
    var context: () -> Context = { Context() }
    var onCall: (Call) async -> Void = { _ in }
    private(set) var state = RemoteChannels.State(state: "off", detail: "")
    private(set) var voices: [VoiceChoice] = []
    private var seen = Set<String>()
    private var placed: [Date] = []
    private var task: Task<Void, Never>?
    private var lastSync = ""

    init(apiKey: String, voice: String, line: String) {
        self.apiKey = apiKey; self.voice = voice
        self.line = line == "dedicated_imessage_number" ? line : "shared_imessage_number"
    }

    static func isPhoneNumber(_ text: String) -> Bool { phone.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }

    /// The call instructions, built from the Bot. Always within Inkbox's 8,000 character limit.
    static func instructions(_ context: Context) -> String {
        var out = "You are \(context.botName), a personal AI assistant, speaking with \(context.ownerName.isEmpty ? "your owner" : context.ownerName) on the phone. "
        if !context.purpose.isEmpty { out += "Your job: \(context.purpose.prefix(400)) " }
        out += "Talk like a person: short sentences, warm, no lists, no spelling out links or symbols. Answer at once and ask one question at a time. "
        out += "You can talk and remember, but you cannot run tools, browse, send messages or change anything during a call. When something needs doing, say you will follow up in the chat and write it down as an action item; the real assistant picks it up right after the call. "
        out += "Never read out passwords or codes. Do not confirm purchases, deletions or messages to other people on a call."
        if !context.summary.isEmpty { out += "\n\nWhat you know so far:\n\(context.summary.prefix(3000))" }
        var list = ""
        for note in context.memory where !note.isEmpty {
            let row = "- " + String(note.prefix(300)) + "\n"
            if (out + "\n\nThings to remember:\n" + list + row).count > instructionsMax { break }
            list += row
        }
        if !list.isEmpty { out += "\n\nThings to remember:\n" + list.trimmingCharacters(in: .newlines) }
        return String(out.prefix(instructionsMax))
    }

    // MARK: Calls out to Inkbox

    private func api(_ path: String, method: String = "GET", json: Any? = nil) async throws -> Any? {
        let reply = try await ChannelHTTP.request(Self.base + path, method: method, headers: ["X-API-Key": apiKey], json: json)
        switch reply.status {
        case 200..<300: return reply.body
        case 401: throw ChannelError(message: "Inkbox did not accept that API key.", code: 401)
        case 403: throw ChannelError(message: "Inkbox says this key cannot use phone calls. Turn on Voice AI and calls for the agent in the Inkbox console.", code: 403)
        case 429: throw ChannelError(message: "Inkbox says the call limit was reached.", code: 429)
        default:
            let detail = (reply.body as? [String: Any])?["detail"] as? String
            throw ChannelError(message: "Inkbox answered \(reply.status)" + (detail.map { ": " + String($0.prefix(200)) } ?? "") + ".", code: reply.status)
        }
    }

    /// Puts the Bot's name, style, summary and notes into the voice agent. Skipped when nothing changed.
    @discardableResult
    func syncInstructions(force: Bool = false) async throws -> Bool {
        let text = Self.instructions(context())
        let signature = text + "|" + voice
        if !force, signature == lastSync { return false }
        _ = try await api("/hosted-agent-config", method: "PUT", json: ["instructions": text, "voice": voice.isEmpty ? (NSNull() as Any) : (voice as Any)])
        lastSync = signature; return true
    }

    func loadVoices() async {
        guard let body = try? await api("/hosted-agent-voices") else { return }
        let list = (body as? [[String: Any]]) ?? ((body as? [String: Any])?["voices"] as? [[String: Any]]) ?? []
        voices = list.compactMap { item in
            guard let id = (item["id"] as? String) ?? (item["voice"] as? String), !id.isEmpty else { return nil }
            return VoiceChoice(id: id, name: (item["name"] as? String) ?? (item["display_name"] as? String) ?? id, available: item["available"] as? Bool ?? true)
        }
    }

    /// Phones a person. `reason` is the voice agent's brief for the call. Only a handful an hour.
    func placeCall(to number: String, reason: String) async throws {
        guard Self.isPhoneNumber(number) else { throw ChannelError(message: "Add your own phone number (like +15551234567) first.") }
        let text = String(reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(Self.reasonMax))
        guard !text.isEmpty else { throw ChannelError(message: "A call needs a reason.") }
        placed = placed.filter { Date().timeIntervalSince($0) < 3600 }
        guard placed.count < Self.callsPerHour else { throw ChannelError(message: "That is five calls in the last hour. Try again later.") }
        placed.append(Date())
        do {
            let body: [String: Any] = ["origination": line, "to_number": number, "mode": "hosted_agent", "reason": text, "on_voicemail": "leave_message"]
            if let call = try await api("/place-call", method: "POST", json: body) as? [String: Any], let id = call["id"] as? String { seen.insert(id) }
        } catch { _ = placed.popLast(); throw error }
    }

    // MARK: Bringing finished calls back

    private func recent() async throws -> [[String: Any]] { (try await api("/calls?limit=20") as? [[String: Any]]) ?? [] }
    private func finished(_ call: [String: Any]) -> Bool {
        call["ended_at"] is String && ["completed", "failed", "canceled"].contains(call["status"] as? String ?? "")
    }

    func start() async throws {
        guard apiKey.count >= 10 else { throw ChannelError(message: "Paste the Inkbox API key first.") }
        for call in try await recent() where finished(call) { if let id = call["id"] as? String { seen.insert(id) } }
        state = .init(state: "on", detail: "Phone calls ready")
        task = Task { [weak self] in await self?.loop() }
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.syncInstructions() } catch { self.state = .init(state: "error", detail: error.localizedDescription) }
            await self.loadVoices()
        }
    }

    func stop() { task?.cancel(); task = nil; state = .init(state: "off", detail: "") }

    private func loop() async {
        while !Task.isCancelled {
            var wait: UInt64 = 10
            do {
                let fresh = try await recent().filter { finished($0) && !seen.contains(($0["id"] as? String) ?? "") }.reversed()
                for call in fresh {
                    guard let id = call["id"] as? String else { continue }
                    seen.insert(id)
                    let rows = ((try? await api("/calls/\(id)/transcripts")) as? [[String: Any]] ?? []).sorted { (($0["seq"] as? Int) ?? 0) < (($1["seq"] as? Int) ?? 0) }
                    let transcript = rows.compactMap { row -> Line? in
                        guard let text = row["text"] as? String, !text.isEmpty else { return nil }
                        return Line(fromPerson: (row["party"] as? String) != "local", text: text)
                    }
                    let items = ((call["post_call_action_items"] as? [[String: Any]]) ?? []).compactMap { row -> Item? in
                        guard let action = row["action"] as? String else { return nil }
                        return Item(action: action, details: (row["details"] as? String) ?? "")
                    }
                    var seconds = 0
                    let parser = ISO8601DateFormatter()
                    if let a = (call["started_at"] as? String).flatMap({ parser.date(from: $0) }), let b = (call["ended_at"] as? String).flatMap({ parser.date(from: $0) }) { seconds = max(0, Int(b.timeIntervalSince(a))) }
                    await onCall(Call(id: id, direction: (call["direction"] as? String) ?? "", number: (call["remote_phone_number"] as? String) ?? "", reason: (call["reason"] as? String) ?? "",
                                      status: (call["status"] as? String) ?? "", outcome: (call["hangup_reason"] as? String) ?? "", seconds: seconds, transcript: transcript, items: items))
                }
                if seen.count > 500 { seen = Set(seen.suffix(250)) }
                state = .init(state: "on", detail: "Phone calls ready")
            } catch let error as ChannelError {
                if Task.isCancelled { return }
                if error.code == 401 { state = .init(state: "error", detail: error.message); return }
                state = .init(state: "error", detail: "Reconnecting: \(error.message)"); wait = 40
            } catch {
                if Task.isCancelled { return }
                state = .init(state: "error", detail: "Reconnecting: \(error.localizedDescription)"); wait = 40
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }
}
