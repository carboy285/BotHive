import XCTest
import CryptoKit
#if os(macOS)
@testable import GrokBotMac
#else
@testable import GrokBot
#endif

final class CloudTests: XCTestCase {
    func testEncryptionBindsOwnerPeersRequestAndDirection() throws {
        let owner = UUID(), host = CloudIdentity(), phone = CloudIdentity(), intruder = CloudIdentity(), id = UUID()
        func device(_ identity: CloudIdentity, kind: String) throws -> CloudDevice { CloudDevice(id:identity.id,name:kind,kind:kind,public_key:try identity.publicKey,last_seen:Date(),available:true) }
        let desktop = try device(host,kind:"host"), controller = try device(phone,kind:"controller")
        let plain = Data("Private chat and memory".utf8)
        let packet = try phone.seal(plain,to:desktop,owner:owner,id:id,kind:"request")
        XCTAssertEqual(try host.open(packet,from:controller,owner:owner),plain)
        XCTAssertFalse(packet.ciphertext.contains("Private"))
        XCTAssertThrowsError(try host.open(packet,from:controller,owner:UUID()))
        XCTAssertThrowsError(try intruder.open(packet,from:controller,owner:owner))
        var tampered = packet; tampered.id = UUID(); XCTAssertThrowsError(try host.open(tampered,from:controller,owner:owner))
        tampered = packet; tampered.kind = "response"; XCTAssertThrowsError(try host.open(tampered,from:controller,owner:owner))
        tampered = packet; tampered.recipient = UUID(); XCTAssertThrowsError(try host.open(tampered,from:controller,owner:owner))
        tampered = packet; tampered.created_at = Date().addingTimeInterval(-130); XCTAssertThrowsError(try host.open(tampered,from:controller,owner:owner))
        var expired = try phone.seal(plain,to:desktop,owner:owner,id:UUID(),kind:"request",now:Date().addingTimeInterval(-130))
        expired.created_at = Date() // A relay changing its timestamp cannot extend encrypted expiry.
        XCTAssertThrowsError(try host.open(expired,from:controller,owner:owner))
        let reply = try host.seal(Data("result".utf8),to:controller,owner:owner,id:id,kind:"response")
        XCTAssertEqual(try phone.open(reply,from:desktop,owner:owner),Data("result".utf8))
    }
    func testStreamingDeltaChangesDeletesAndResyncsWithoutSessions() throws {
        let bot = Workspace.fresh.bots[0]
        var previous = RemoteSnapshot(hostName:"Mac",revision:"one",workspace:Workspace(bots:[bot]),running:[],providers:[])
        previous.workspace.entries = [Entry(botID:bot.id,kind:.user,text:"hello"),Entry(botID:bot.id,kind:.bot,text:"start")]
        var next = previous; next.revision = "two"; next.workspace.entries[1].text = "streamed result"
        next.workspace.entries.append(Entry(botID:bot.id,kind:.activity,text:"done"))
        let patch = try CloudStatePatch.make(next,previous:previous)
        XCTAssertEqual(patch.snapshot.workspace.entries.count,2)
        let rebuilt = try patch.applying(to:previous)
        XCTAssertEqual(try CloudCoding.encoder().encode(rebuilt),try CloudCoding.encoder().encode(next))
        XCTAssertThrowsError(try patch.applying(to:nil))
        next.revision = "three"; next.workspace.entries.removeFirst()
        let deletion = try CloudStatePatch.make(next,previous:rebuilt)
        XCTAssertEqual(deletion.removedEntries.count,1)
        XCTAssertEqual(try deletion.applying(to:rebuilt).workspace.entries.count,2)
    }
    @MainActor
    func testLocalApprovalPinsAndRevokesIdentity() async throws {
        let secrets = KeychainSecretStore(service:"cloud-approval-test." + UUID().uuidString)
        let owner = UUID(), host = CloudIdentity(), phone = CloudIdentity()
        let session = CloudSession(access_token:"fixture",refresh_token:"refresh",expires_at:Date().timeIntervalSince1970+3600,user:CloudUser(id:owner,email:"fixture@example.test"))
        try secrets.save(JSONEncoder().encode(session),account:"session")
        defer { for key in ["session","identity-" + owner.uuidString,"approved-" + owner.uuidString,"hosts-" + owner.uuidString] { try? secrets.delete(account:key) } }
        let account = CloudAccount(kind:"host",secrets:secrets)
        var controller = CloudDevice(id:phone.id,name:"Phone",kind:"controller",public_key:try phone.publicKey,last_seen:Date(),available:true)
        XCTAssertFalse(account.approved(controller));try account.approve(controller,allowed:true);XCTAssertTrue(account.approved(controller))
        let restored = CloudAccount(kind:"host",secrets:secrets);XCTAssertTrue(restored.approved(controller))
        controller.public_key = try CloudIdentity().publicKey;XCTAssertFalse(restored.approved(controller))
        try account.approve(controller,allowed:false);XCTAssertFalse(account.approved(controller))
        var desktop = CloudDevice(id:host.id,name:"Mac",kind:"host",public_key:try host.publicKey,last_seen:Date(),available:true)
        try account.pin(desktop);desktop.public_key = try CloudIdentity().publicKey;XCTAssertThrowsError(try account.pin(desktop))
        await account.signOut();XCTAssertFalse(account.signedIn);XCTAssertNil(account.identity)
    }

    // MARK: 0.9.9 wake channel

    func testWakeChannelTopicAndJoinFrame() throws {
        let device = UUID(uuidString: "A0B418E3-8581-4F21-B136-CF0039F1B001")!
        // Postgres prints UUIDs in lower case; the channel name must match the migration's 'opengrok:' || id::text.
        XCTAssertEqual(CloudWake.topic(device), "realtime:opengrok:a0b418e3-8581-4f21-b136-cf0039f1b001")
        let frame = CloudWake.joinFrame(topic: CloudWake.topic(device), token: "jwt", ref: "1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "phx_join")
        XCTAssertEqual(object["ref"] as? String, "1")
        XCTAssertEqual(object["join_ref"] as? String, "1")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt")
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(config["private"] as? Bool, true)
        let url = try XCTUnwrap(CloudWake.socketURL())
        XCTAssertEqual(url.scheme, "wss"); XCTAssertEqual(url.path, "/realtime/v1/websocket")
        XCTAssertEqual(url.host, CloudConfiguration.url.host)
    }

    func testWakeChannelReadsServerFrames() {
        let topic = "realtime:opengrok:abc"
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:abc","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}"#, topic: topic), .joined)
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:abc","event":"phx_reply","payload":{"status":"error","response":{"reason":"Unauthorized"}},"ref":"1"}"#, topic: topic), .closed)
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:abc","event":"broadcast","payload":{"type":"broadcast","event":"packet","payload":{}},"ref":null}"#, topic: topic), .wake)
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:abc","event":"system","payload":{"status":"error","message":"denied"},"ref":null}"#, topic: topic), .closed)
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:abc","event":"phx_close","payload":{},"ref":null}"#, topic: topic), .closed)
        // Heartbeat replies and other channels' traffic are ignored.
        XCTAssertEqual(CloudWake.parse(#"{"topic":"phoenix","event":"phx_reply","payload":{"status":"ok"},"ref":"7"}"#, topic: topic), .other)
        XCTAssertEqual(CloudWake.parse(#"{"topic":"realtime:opengrok:other","event":"broadcast","payload":{},"ref":null}"#, topic: topic), .other)
        XCTAssertEqual(CloudWake.parse("not json", topic: topic), .other)
    }

    @MainActor
    func testPulseWakesWaitersAndNeverLosesAnEarlyPing() async {
        let pulse = CloudPulse()
        let seen = pulse.count
        pulse.signal() // Lands before the wait starts: must still count.
        let early = await pulse.wait(after: seen, upTo: .seconds(1))
        XCTAssertTrue(early)
        let quiet = await pulse.wait(after: pulse.count, upTo: .milliseconds(50))
        XCTAssertFalse(quiet)
    }
}
