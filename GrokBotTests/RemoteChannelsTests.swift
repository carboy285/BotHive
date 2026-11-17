import XCTest
#if os(macOS)
@testable import GrokBotMac
#else
@testable import GrokBot
#endif

final class RemoteChannelsTests: XCTestCase {
    /// The shape the Windows app and Docker server report in their host settings (secrets arrive only as true or false).
    private let sample = """
    {"hostName":"box","platform":"windows","appVersion":"10.1.2","providers":[],"apiKeys":{},"voiceKeys":{},
     "connectors":{"configured":false,"toolkits":[]},"sharing":false,"admin":true,
     "channels":{"bot":"7F2E3B0A-1111-4222-8333-444455556666",
       "bots":[{"id":"7F2E3B0A-1111-4222-8333-444455556666","name":"Hive"}],
       "calls":{"ready":false,"listening":false},"people":{"telegram":1},"voiceFields":[],
       "channels":{
         "telegram":{"name":"Telegram","enabled":true,"configured":true,"fields":{"token":true},"state":{"state":"on","detail":"@hive_bot"},
                     "approved":[{"id":"555","name":"Sam","at":1700000000000}],"pending":[{"name":"Ann","code":"123456","at":1700000000001}]},
         "sms":{"name":"SMS","enabled":false,"configured":false,"fields":{"number":"+15550001111","authToken":false},"state":{"state":"off","detail":""},"approved":[],"pending":[]}}}}
    """

    func testHostSettingsWithChannelsDecode() throws {
        let settings = try CloudCoding.decoder().decode(RemoteHostSettings.self, from: Data(sample.utf8))
        let channels = try XCTUnwrap(settings.channels)
        XCTAssertEqual(channels.bots.map(\.name), ["Hive"])
        XCTAssertEqual(channels.bot, "7F2E3B0A-1111-4222-8333-444455556666")
        let telegram = try XCTUnwrap(channels.channels["telegram"])
        XCTAssertTrue(telegram.enabled)
        XCTAssertEqual(telegram.state.detail, "@hive_bot")
        XCTAssertEqual(telegram.fields["token"]?.set, true)
        XCTAssertNil(telegram.fields["token"]?.text, "a token is never sent back, only whether it is set")
        XCTAssertEqual(telegram.approved.map(\.id), ["555"])
        XCTAssertEqual(telegram.pending.map(\.code), ["123456"])
        let sms = try XCTUnwrap(channels.channels["sms"])
        XCTAssertEqual(sms.fields["number"]?.text, "+15550001111")
        XCTAssertEqual(sms.fields["authToken"]?.set, false)
    }

    func testOlderServersWithoutChannelsStillDecode() throws {
        let old = #"{"hostName":"box","platform":"windows","appVersion":"10.1.1","providers":[],"apiKeys":{},"voiceKeys":{},"connectors":{"configured":false,"toolkits":[]},"sharing":false}"#
        XCTAssertNil(try CloudCoding.decoder().decode(RemoteHostSettings.self, from: Data(old.utf8)).channels)
    }

    func testChannelCommandsCarryTheirFields() throws {
        let command = RemoteCommand(action: "channels_configure", text: nil, name: "telegram", fields: ["token": "123:abc"])
        let data = try CloudCoding.encoder().encode(command)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "channels_configure")
        XCTAssertEqual(object["name"] as? String, "telegram")
        XCTAssertEqual((object["fields"] as? [String: String])?["token"], "123:abc")
    }
}
