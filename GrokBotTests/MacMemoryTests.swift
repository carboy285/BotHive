import XCTest
#if os(macOS)
@testable import GrokBotMac

@MainActor
final class MacMemoryTests: XCTestCase {
    private func model(deferSaves: Bool = false) throws -> (AppModel, Bot) {
        let store = WorkspaceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("preview.json"))
        let app = AppModel(store: store, deferSaves: deferSaves); app.enterPreview()
        return (app, try XCTUnwrap(app.workspace.bots.first))
    }

    func testRecallRanksOverlapAndIgnoresShortWords() {
        let items = [
            MacMemory.Memo(text: "the plumber Marta charges 80 an hour", day: "2026-01-02", fromPerson: true),
            MacMemory.Memo(text: "lunch is at noon", day: "2026-01-03", fromPerson: true),
            MacMemory.Memo(text: "my plumber is late again", day: "2026-01-04", fromPerson: true),
        ]
        let found = MacMemory.rank("what did the plumber charge", items)
        XCTAssertEqual(found.first?.text, "the plumber Marta charges 80 an hour".replacingOccurrences(of: "charges", with: "charges"))
        XCTAssertFalse(found.contains { $0.text.contains("lunch") })
        XCTAssertTrue(MacMemory.rank("", items).isEmpty)
        XCTAssertEqual(MacMemory.words("An AI, a go!"), [])
    }

    func testAPassReplyIsParsedOnlyWhenItIsTheRequestedObject() {
        let parsed = MacMemory.parse("Here you go: {\"summary\":\"S\",\"remember\":[\"a\",5,\"  b  \"]} done")
        XCTAssertEqual(parsed, MacMemory.Outcome(summary: "S", remember: ["a", "b"], memory: nil))
        XCTAssertNil(MacMemory.parse("sorry, I cannot do that"))
        XCTAssertNotNil(MacMemory.parse("{\"summary\":\"s\",\"remember\":[],\"memory\":[\"x\"]}")?.memory)
    }

    func testThePromptAsksForAMergeOnlyWhenNotesPileUp() throws {
        var (_, bot) = try model()
        XCTAssertFalse(MacMemory.prompt(bot: bot, entries: []).contains("\"memory\":[\"...\"]"))
        bot.memory = (0..<MacMemory.mergeAt).map { "fact \($0)" }
        XCTAssertTrue(MacMemory.prompt(bot: bot, entries: []).contains("\"memory\":[\"...\"]"))
    }

    func testASummaryAndLastingFactsAreWrittenAfterTenMessages() async throws {
        let (app, bot) = try model()
        let memory = MacMemory(); memory.app = app
        var prompts: [String] = []
        memory.quickTurn = { _, prompt in prompts.append(prompt); return "{\"summary\":\"Sam sees Dr Okafor.\",\"remember\":[\"Sam\u{2019}s dentist is Dr Okafor\"]}" }
        for index in 0..<9 { app.addNote("[iMessage \u{00B7} Sam] message \(index) my dentist is Dr Okafor", to: bot) }
        let quiet = await memory.noteActivity(bot)
        XCTAssertFalse(quiet); XCTAssertTrue(prompts.isEmpty)
        app.addNote("message 9", to: bot); app.addNote("message 10", to: bot)
        let ran = await memory.noteActivity(bot)
        XCTAssertTrue(ran)
        let updated = try XCTUnwrap(app.workspace.bots.first { $0.id == bot.id })
        XCTAssertEqual(updated.summary, "Sam sees Dr Okafor.")
        XCTAssertEqual(updated.memory, ["Sam\u{2019}s dentist is Dr Okafor"])
        XCTAssertNotNil(updated.summaryAt)
        let again = await memory.noteActivity(bot)
        XCTAssertFalse(again, "nothing new since the last pass")
        XCTAssertTrue(prompts[0].contains("message 10"))
    }

    func testRecallFindsMessagesFromEveryChannelAndTheArchive() async throws {
        let (app, bot) = try model(deferSaves: true)
        let memory = MacMemory(); memory.app = app
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        memory.archiveURL = { folder.appendingPathComponent($0.uuidString + ".jsonl") }
        app.addNote("[Telegram \u{00B7} Sam] the safe code word is pineapple", to: bot)
        for index in 0..<(MacMemory.archiveAt + 5) { app.addNote("filler \(index)", to: bot) }
        app.addNote("[Slack \u{00B7} Lee] the plumber Marta charges 80 an hour", to: bot)
        let moved = memory.archiveIfNeeded()
        XCTAssertEqual(moved, MacMemory.archiveMove)
        XCTAssertLessThan(app.workspace.entries.count, 10_000)
        XCTAssertTrue(memory.recall(bot: bot, query: "pineapple code word").contains("pineapple"), "an archived message is still found")
        XCTAssertTrue(memory.recall(bot: bot, query: "what did the plumber charge").contains("Slack \u{00B7} Lee \u{00B7} the plumber Marta"))
        XCTAssertTrue(memory.recall(bot: bot, query: "zebra giraffe").contains("nothing found"))
        XCTAssertEqual(memory.archiveIfNeeded(), 0)
    }

    func testChannelMessagePicturesAreJudgedByTheirBytes() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        var heic = Data([0, 0, 0, 24]); heic.append(Data("ftypheic".utf8)); heic.append(Data(count: 16))
        XCTAssertEqual(ChannelMediaStore.sniff(jpeg), .jpg); XCTAssertEqual(ChannelMediaStore.sniff(png), .png)
        XCTAssertEqual(ChannelMediaStore.sniff(heic), .heic); XCTAssertEqual(ChannelMediaStore.sniff(Data("GIF89a......".utf8)), .gif)
        XCTAssertNil(ChannelMediaStore.sniff(Data("hello world, not an image".utf8)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = try await ChannelMediaStore.store(jpeg, name: "a.png", into: folder)
        XCTAssertTrue(name.hasSuffix(".jpg"), "named after what it is, not what the sender called it")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Attachments").appendingPathComponent(name)), jpeg)
        do { _ = try await ChannelMediaStore.store(Data("not an image at all".utf8), name: "x", into: folder); XCTFail("should refuse") }
        catch let error as ChannelError { XCTAssertEqual(error.code, 1) }
    }

    func testTheCallInstructionsCarryTheBotAndStayWithinInkboxsLimit() {
        var context = InkboxVoiceClient.Context(botName: "Hive", purpose: "Runs my errands", summary: "Sam likes tea.", memory: ["Dentist is Dr Okafor"], ownerName: "Sam")
        let text = InkboxVoiceClient.instructions(context)
        XCTAssertTrue(text.contains("You are Hive")); XCTAssertTrue(text.contains("Sam likes tea.")); XCTAssertTrue(text.contains("Dentist is Dr Okafor")); XCTAssertTrue(text.contains("cannot run tools"))
        context.summary = String(repeating: "x", count: 20_000); context.memory = (0..<100).map { String(repeating: "fact ", count: 60) + "\($0)" }
        XCTAssertLessThanOrEqual(InkboxVoiceClient.instructions(context).count, InkboxVoiceClient.instructionsMax)
        XCTAssertTrue(InkboxVoiceClient.isPhoneNumber("+15551234567")); XCTAssertFalse(InkboxVoiceClient.isPhoneNumber("555-1234"))
    }

    func testABotWithASummaryRoundTrips() throws {
        var bot = Bot(id: UUID(), name: "Hive", purpose: "x", color: "white", symbol: "sparkles")
        bot.summary = "Sam is busy."; bot.summaryAt = UUID()
        let decoded = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        XCTAssertEqual(decoded, bot)
        let older = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","name":"A","purpose":"p","color":"white","symbol":"sparkles"}"#.utf8))
        XCTAssertNil(older.summary)
    }
}
#endif
