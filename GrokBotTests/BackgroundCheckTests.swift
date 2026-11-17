import XCTest
#if os(iOS)
@testable import GrokBot

final class BackgroundCheckTests: XCTestCase {
    private let bot = UUID()
    private func entry(_ kind: Entry.Kind, _ seconds: TimeInterval, state: MessageState? = nil) -> Entry {
        var value = Entry(botID: bot, kind: kind, text: "hello", date: Date(timeIntervalSince1970: 1_000 + seconds))
        value.state = state
        return value
    }

    func testOnlyFinishedBotMessagesAfterTheWatermarkAreNew() {
        let since = Date(timeIntervalSince1970: 1_100)
        let entries = [entry(.bot, 50), entry(.bot, 150), entry(.user, 160), entry(.activity, 170), entry(.bot, 180, state: .stopped), entry(.bot, 190, state: .streaming), entry(.bot, 200, state: .failed)]
        XCTAssertEqual(BackgroundCheck.fresh(in: entries, since: since).map(\.date.timeIntervalSince1970), [1_150, 1_200])
    }

    func testTheWatermarkStopsBeforeAReplyStillStreaming() {
        let entries = [entry(.bot, 100), entry(.bot, 200, state: .streaming), entry(.user, 300)]
        let next = BackgroundCheck.nextWatermark(entries: entries, current: Date(timeIntervalSince1970: 1_000))
        XCTAssertLessThan(next!, Date(timeIntervalSince1970: 1_200))
        XCTAssertGreaterThanOrEqual(next!, Date(timeIntervalSince1970: 1_100))
        // Once that reply finishes (same date), it is newer than the watermark and gets announced.
        XCTAssertEqual(BackgroundCheck.fresh(in: [entry(.bot, 200, state: .complete)], since: next!).count, 1)
    }

    func testTheWatermarkNeverMovesBackAndSurvivesNoMessages() {
        let current = Date(timeIntervalSince1970: 5_000)
        XCTAssertEqual(BackgroundCheck.nextWatermark(entries: [entry(.bot, 10)], current: current), current)
        XCTAssertEqual(BackgroundCheck.nextWatermark(entries: [], current: current), current)
        XCTAssertNil(BackgroundCheck.nextWatermark(entries: [], current: nil))
    }
}
#endif
