import XCTest
#if os(macOS)
@testable import GrokBotMac
#else
@testable import GrokBot
#endif

final class ServerAddressTests: XCTestCase {
    func testAddressesPeopleTypeBecomeACleanOrigin() throws {
        XCTAssertEqual(try ServerAddress.normalize("https://my-box.tailnet-name.ts.net"), ServerAddress.Parsed(origin: "https://my-box.tailnet-name.ts.net", host: "my-box.tailnet-name.ts.net", https: true))
        XCTAssertEqual(try ServerAddress.normalize("http://100.101.102.103:8765/").origin, "http://100.101.102.103:8765")
        XCTAssertEqual(try ServerAddress.normalize("100.101.102.103:8765").origin, "http://100.101.102.103:8765")
        XCTAssertEqual(try ServerAddress.normalize("192.168.1.20:8765").origin, "http://192.168.1.20:8765")
        XCTAssertEqual(try ServerAddress.normalize("my-box").origin, "http://my-box")
        XCTAssertEqual(try ServerAddress.normalize("bots.example.com").origin, "https://bots.example.com")
        XCTAssertEqual(try ServerAddress.normalize("  HTTPS://Bots.Example.com  ").origin, "https://bots.example.com")
        XCTAssertEqual(try ServerAddress.normalize("https://bots.example.com:443").origin, "https://bots.example.com")
    }

    func testUnsafeOrWrongAddressesAreRefused() {
        let bad = ["", "   ", "ftp://x.example.com", "javascript:alert(1)", "file:///etc/passwd", "https://user:pw@x.example.com", "https://x.example.com/page",
                   "https://x.example.com/?a=1", "https://x.example.com/#top", "http://bots.example.com", "http://8.8.8.8:8765", "https://", String(repeating: "x", count: 400)]
        for input in bad { XCTAssertThrowsError(try ServerAddress.normalize(input), input) }
        XCTAssertTrue((try? ServerAddress.normalize("http://bots.example.com")) == nil)
    }

    func testPrivateHostsAreTheOnesPlainHttpMayReach() {
        for host in ["100.64.0.1", "100.127.255.254", "10.0.0.5", "192.168.0.9", "172.16.1.1", "127.0.0.1", "localhost", "mac.local", "box.tailnet.ts.net", "my-box"] {
            XCTAssertTrue(ServerAddress.isPrivate(host), host)
        }
        for host in ["8.8.8.8", "100.128.0.1", "172.32.0.1", "example.com", "x.y.z", "300.1.1.1"] { XCTAssertFalse(ServerAddress.isPrivate(host), host) }
    }

    func testSavedListKeepsValidEntriesAndIsCapped() {
        let good = SavedServer(name: "Home", url: "https://box.ts.net")
        let kept = ServerAddress.clean([good, SavedServer(name: "bad", url: "https://a.example.com/page"), SavedServer(name: " ", url: "https://box.ts.net")])
        XCTAssertEqual(kept, [good])
        let many = (0..<40).map { SavedServer(name: "n\($0)", url: "https://box.ts.net") }
        XCTAssertEqual(ServerAddress.clean(many).count, ServerAddress.maxServers)
        XCTAssertEqual(ServerAddress.cleanName("  Home\nlab  ", fallback: "x"), "Home lab")
        XCTAssertEqual(ServerAddress.cleanName("", fallback: "Fallback"), "Fallback")
    }
}
