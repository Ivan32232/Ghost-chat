import XCTest
@testable import GhostChat

final class PushManagerTests: XCTestCase {

    private func manager() -> PushManager {
        PushManager(baseURL: URL(string: "https://ghostchat.one")!)
    }

    func test_initialTokens_areNil() {
        let m = manager()
        XCTAssertNil(m.voipToken)
        XCTAssertNil(m.apnsToken)
        XCTAssertNil(m.pushAuth)
    }

    func test_didReceiveAPNsToken_setsStateAndYields() async {
        let m = manager()
        let token = Data([0xAA, 0xBB])
        let expectation = expectation(description: "yielded")
        Task {
            for await t in m.apnsTokens {
                XCTAssertEqual(t, token)
                expectation.fulfill()
                break
            }
        }
        m.didReceiveAPNsToken(token)
        XCTAssertEqual(m.apnsToken, token)
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_pushAuth_settable() {
        let m = manager()
        m.pushAuth = "deadbeef"
        XCTAssertEqual(m.pushAuth, "deadbeef")
    }
}

final class TURNCredentialsPushAuthTests: XCTestCase {

    func test_pushAuth_decodesFromJSON() throws {
        let raw = #"""
        {"username":"u","credential":"c","urls":["turn:x"],"ttl":3600,"pushAuth":"abc"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TURNCredentials.self, from: raw)
        XCTAssertEqual(decoded.pushAuth, "abc")
    }

    func test_pushAuth_missing_isNil() throws {
        let creds = TURNCredentials(username: "u", credential: "c", urls: [], ttl: 60)
        XCTAssertNil(creds.pushAuth)
    }
}
