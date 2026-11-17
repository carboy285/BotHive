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
        XCTAssertTrue(problem?.contains("Bothive server") == true)
    }

    func testABotIsToldNothingWhenNoChannelIsConnected() {
        let bot = Bot(id: UUID(), name: "Hive", purpose: "Help", color: "white", symbol: "sparkles")
        XCTAssertEqual(MacChannels().note(for: bot), "")
    }
}
#endif
