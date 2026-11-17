import XCTest
#if os(macOS)
@testable import GrokBotMac

@MainActor
final class MacChannelsTests: XCTestCase {
    func testLongRepliesAreSplitAtNaturalBreaks() {
        let text = String(repeating: "a", count: 30) + "\n\n" + String(repeating: "b", count: 30) + " " + String(repeating: "c", count: 30)
        let pieces = MacChannels.chunks(text, limit: 40)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 40 })
        XCTAssertEqual(pieces.joined().filter { !$0.isWhitespace }.count, 90)
        XCTAssertEqual(MacChannels.chunks("short", limit: 100), ["short"])
        XCTAssertEqual(MacChannels.chunks("   ", limit: 100), [])
    }

    func testTokensAreSecretsAndNumbersAreNot() {
        for key in ["token", "botToken", "appToken", "apiKey", "authToken", "pin"] { XCTAssertTrue(MacChannels.isSecret(key), key) }
        for key in ["number", "ownerNumber", "publicUrl", "language"] { XCTAssertFalse(MacChannels.isSecret(key), key) }
    }

    func testAChannelCannotBeTurnedOnBeforeItIsSetUp() async {
        let channels = MacChannels()
        let problem = await channels.execute("channels_enable", channel: "telegram", text: "on", fields: nil)
        XCTAssertEqual(problem, "Finish setting up Telegram first.")
        XCTAssertNil(MacChannels.info("sms"), "SMS and calls run on a server, not on the Mac")
    }

    func testSavedTokensAreNeverReportedBack() async {
        let channels = MacChannels()
        let problem = await channels.execute("channels_configure", channel: "telegram", text: nil, fields: ["token": "123:secret-token"])
        XCTAssertNil(problem)
        let telegram = channels.status().channels["telegram"]
        XCTAssertEqual(telegram?.configured, true)
        XCTAssertEqual(telegram?.fields["token"]?.set, true)
        XCTAssertNil(telegram?.fields["token"]?.text, "only whether it is set")
        XCTAssertFalse(String(describing: channels.status()).contains("secret-token"))
        // A blank secret keeps the saved one; a rejected value is refused.
        _ = await channels.execute("channels_configure", channel: "telegram", text: nil, fields: ["token": ""])
        XCTAssertEqual(channels.status().channels["telegram"]?.configured, true)
        let bad = await channels.execute("channels_configure", channel: "telegram", text: nil, fields: ["token": "a\nb"])
        XCTAssertEqual(bad, "One of the values is not valid.")
        _ = await channels.execute("channels_configure", channel: "telegram", text: nil, fields: ["token": ""])
    }

    func testPhoneCallsAreExplainedNotAttempted() async {
        let problem = await MacChannels().execute("channels_test_call", channel: nil, text: nil, fields: nil)
        XCTAssertTrue(problem?.contains("Inkbox") == true, "calls on the Mac go through Inkbox")
        XCTAssertTrue(problem?.contains("Bothive server") == true, "Twilio calls stay on a server")
    }

    func testABotIsToldNothingWhenNoChannelIsConnected() {
        let bot = Bot(id: UUID(), name: "Hive", purpose: "Help", color: "white", symbol: "sparkles")
        XCTAssertEqual(MacChannels().note(for: bot), "")
    }

    // MARK: Channels v2 (10.1.2): read at once, bursts, steering, photos, owner, reaching out

    @MainActor private final class FakeAdapter: ChannelAdapter {
        var state = RemoteChannels.State(state: "on", detail: "")
        var events: [String] = []
        var sent: [(chat: String, text: String)] = []
        func start() async throws {}
        func stop() {}
        func send(chat: String, text: String) async throws { sent.append((chat, text)) }
        func typing(chat: String) async { events.append("typing") }
        func acknowledge(_ message: ChannelMessage) async { events.append("read") }
    }

    private struct Rig {
        let channels: MacChannels
        let app: AppModel
        let bot: Bot
        let adapter: FakeAdapter
    }

    private func rig(channel: String = "telegram", me: Bool = false, seen: Date? = Date()) throws -> Rig {
        let store = WorkspaceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("preview.json"))
        let app = AppModel(store: store); app.enterPreview()
        let bot = try XCTUnwrap(app.workspace.bots.first)
        let channels = MacChannels(); channels.app = app; channels.batchWindow = 0
        var config = MacChannels.Config(); config.bot = bot.id.uuidString
        channels.configureForTesting(config)
        let adapter = FakeAdapter(); channels.install(adapter, for: channel)
        channels.approveForTesting(channel, person: MacChannels.Person(id: "7", name: "Sam", chatID: "7", at: Date(), lastSeen: seen, me: me ? true : nil))
        return Rig(channels: channels, app: app, bot: bot, adapter: adapter)
    }

    private func message(_ text: String, from sender: String = "7", media: [ChannelMedia] = []) -> ChannelMessage {
        ChannelMessage(senderID: sender, senderName: "Sam", chatID: sender, text: text, media: media)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAnApprovedMessageIsMarkedReadAndAStrangerGetsOnlyACode() async throws {
        let r = try rig()
        var asked: [String] = []
        r.channels.askOverride = { _, _, text, _, _ in asked.append(text); return "the answer" }
        await r.channels.inbound("telegram", message("let me in", from: "9"))
        XCTAssertTrue(r.adapter.events.isEmpty, "a stranger is not acknowledged")
        XCTAssertTrue(asked.isEmpty, "nothing a stranger writes reaches the Bot")
        XCTAssertTrue(r.adapter.sent.first?.text.contains("Your code is") == true)
        await r.channels.inbound("telegram", message("what is on today?"))
        await settle { r.adapter.events.contains("read") }
        XCTAssertTrue(r.adapter.events.contains("read") && r.adapter.events.contains("typing"))
        XCTAssertEqual(asked, ["what is on today?"])
        XCTAssertEqual(r.adapter.sent.last?.text, "the answer")
    }

    func testABurstOfMessagesBecomesOneRequestWithThePictureKept() async throws {
        let r = try rig(); r.channels.batchWindow = 0.2
        var asked: [(String, [ChannelMedia])] = []
        r.channels.askOverride = { _, _, text, media, _ in asked.append((text, media)); return "done" }
        let photo = ChannelMedia(url: "https://x.example/a.jpg", contentType: "image/jpeg")
        async let first: Void = r.channels.inbound("telegram", message("", media: [photo]))
        async let second: Void = r.channels.inbound("telegram", message("add these to my reminders"))
        _ = await (first, second)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, "add these to my reminders")
        XCTAssertEqual(asked.first?.1, [photo])
    }

    func testAMessageWhileTheBotWorksSteersItAndStopOnlyStops() async throws {
        let r = try rig()
        var asked: [(String, Bool)] = [], stops = 0
        var release: CheckedContinuation<Void, Never>?
        r.channels.onStop = { _ in stops += 1 }
        r.channels.askOverride = { _, _, text, _, steer in
            asked.append((text, steer))
            if text == "slow" { await withCheckedContinuation { release = $0 }; return nil }
            return steer ? "carrying on" : "ok"
        }
        await r.channels.inbound("telegram", message("stop"))
        XCTAssertEqual(r.adapter.sent.last?.text, "Nothing is running right now.")
        let slow = Task { await r.channels.inbound("telegram", message("slow")) }
        await settle { release != nil }
        let next = Task { await r.channels.inbound("telegram", message("actually make it short")) }
        await settle { stops == 1 }
        XCTAssertEqual(stops, 1); XCTAssertEqual(asked.count, 1, "the new turn waits for the stopped one")
        release?.resume()
        await slow.value; await next.value
        XCTAssertEqual(asked.map(\.0), ["slow", "actually make it short"]); XCTAssertEqual(asked.last?.1, true)
        XCTAssertEqual(r.adapter.sent.map(\.text).filter { $0 == "carrying on" }.count, 1)
        XCTAssertFalse(r.adapter.sent.contains { $0.text == "ok" })
        XCTAssertTrue(MacChannels.isStopRequest("Cancel.")); XCTAssertFalse(MacChannels.isStopRequest("stop the presses and call mom"))
    }

    func testYouCanMarkYourselfRenamePeopleAndChangeSettings() async throws {
        let r = try rig(me: false)
        var from: MacChannels.Sender?
        r.channels.askOverride = { _, sender, _, _, _ in from = sender; return "ok" }
        let problem1 = await r.channels.execute("channels_set_person", channel: "telegram", text: "7", fields: ["me": "true", "name": "Sam Rivera"])
        XCTAssertNil(problem1)
        XCTAssertEqual(r.channels.owner(preferred: "telegram")?.person.id, "7")
        XCTAssertEqual(r.channels.status().channels["telegram"]?.approved.first?.name, "Sam Rivera")
        XCTAssertEqual(r.channels.status().channels["telegram"]?.approved.first?.me, true)
        await r.channels.inbound("telegram", message("hello"))
        XCTAssertEqual(from?.name, "Sam Rivera"); XCTAssertEqual(from?.me, true)
        let problem3 = await r.channels.execute("channels_set_person", channel: "telegram", text: "nobody", fields: ["me": "true"])
        XCTAssertEqual(problem3, "That person is not approved.")
        XCTAssertEqual(r.channels.status().settings?.fast, true)
        let problem2 = await r.channels.execute("channels_set_settings", channel: nil, text: nil, fields: ["fast": "false", "quietStart": "23", "escalateMinutes": "999", "whenBusy": "queue"])
        XCTAssertNil(problem2)
        let settings = try XCTUnwrap(r.channels.status().settings)
        XCTAssertEqual([settings.fast, settings.whenBusy == "queue"], [false, true]); XCTAssertEqual(settings.quietStart, 23); XCTAssertEqual(settings.escalateMinutes, 120)
        let problem4 = await r.channels.execute("channels_set_settings", channel: nil, text: nil, fields: ["whenBusy": "later"])
        XCTAssertEqual(problem4, "Choose Steer or Queue.")
    }

    func testTheBotAsksTheOwnerFirstAndTheNextReplyIsTheAnswer() async throws {
        let r = try rig(channel: "imessage", me: true, seen: nil)
        var from: MacChannels.Sender?
        r.channels.askOverride = { _, sender, _, _, _ in from = sender; return "booked" }
        let action = try JSONDecoder().decode(BotAction.self, from: Data(#"{"action":"ask_owner","text":"Should I book 3pm or 5pm? See https://dentist.example or call 555-123-4567 to change it later and tell me which you prefer.","urgent":true}"#.utf8))
        let result = await r.channels.runAction(bot: r.bot, action: action)
        XCTAssertTrue(result.hasPrefix("Asked Sam on iMessage"), result)
        let first = try XCTUnwrap(r.adapter.sent.first?.text)
        XCTAssertLessThanOrEqual(first.count, 159); XCTAssertFalse(first.contains("https")); XCTAssertFalse(first.contains("555-123"))
        XCTAssertNotNil(r.channels.config.pendingAsk); XCTAssertEqual(r.channels.status().inkbox?.pendingAsk?.question.prefix(10), "Should I b")
        await r.channels.inbound("imessage", message("the 5pm one"))
        XCTAssertEqual(from?.replyTo?.prefix(10), "Should I b"); XCTAssertNil(r.channels.config.pendingAsk)
        let nobody = try rig(channel: "imessage", me: false)
        let refused = await nobody.channels.runAction(bot: nobody.bot, action: action)
        XCTAssertTrue(refused.contains("tick Me"), refused)
        for _ in 0..<5 { _ = await r.channels.runAction(bot: r.bot, action: action) }
        let limited = await r.channels.runAction(bot: r.bot, action: action)
        XCTAssertTrue(limited.contains("as many messages"), limited)
    }

    func testAnApprovalPromptGoesToTheOwnersChatOnlyWhenAnOwnerIsSet() async throws {
        let r = try rig(me: true)
        let sent = await r.channels.routeApproval(id: UUID(), title: "Add 6 reminders", detail: "Buy milk")
        XCTAssertTrue(sent); XCTAssertTrue(r.adapter.sent.last?.text.hasPrefix("Needs your OK: Add 6 reminders") == true)
        let other = try rig(me: false)
        let none = await other.channels.routeApproval(id: UUID(), title: "x", detail: "")
        XCTAssertFalse(none, "nobody is marked Me")
    }

    func testAFirstMessageIsShortWithNoLinksOrNumbers() {
        XCTAssertEqual(MacChannels.openingText("Book it? https://x.example now"), "Book it? now")
        let long = MacChannels.openingText(String(repeating: "word ", count: 80))
        XCTAssertLessThanOrEqual(long.count, 159); XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }

    func testAnUrgentQuestionIsRepeatedByTextWhenThereIsNoVoiceLine() async throws {
        let r = try rig(me: true)
        var config = r.channels.config
        config.pendingAsk = MacChannels.PendingAsk(botID: r.bot.id.uuidString, channel: "telegram", senderID: "7", chatID: "7", question: "Server is down, restart it?", askedAt: Date().addingTimeInterval(-11 * 60), urgent: true)
        r.channels.configureForTesting(config)
        await r.channels.checkAsks()
        XCTAssertTrue(r.adapter.sent.last?.text.hasPrefix("Still need your answer") == true)
        XCTAssertEqual(r.channels.config.pendingAsk?.escalated, true)
        r.adapter.sent.removeAll(); await r.channels.checkAsks()
        XCTAssertTrue(r.adapter.sent.isEmpty, "once")
    }
}
#endif
