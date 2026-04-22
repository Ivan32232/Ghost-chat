import XCTest
@testable import GhostChat

@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: - parse()

    func test_parse_customScheme_queryForm() {
        let url = URL(string: "ghostchat://?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_customScheme_pathForm_legacy() {
        // Earlier builds shipped ghostchat://room/<id> — we keep accepting it.
        let url = URL(string: "ghostchat://room/rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_universalLink_https() {
        let url = URL(string: "https://ghostchat.one/?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_universalLink_wwwSubdomain() {
        let url = URL(string: "https://www.ghostchat.one/?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_universalLink_pathForm() {
        // Safari-fallback form: /room/<id> — nginx serves index.html for this path.
        let url = URL(string: "https://ghostchat.one/room/rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_universalLink_pathForm_withTrailingSlash() {
        let url = URL(string: "https://ghostchat.one/room/rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_/")!
        XCTAssertEqual(DeepLinkRouter.parse(url), "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_parse_universalLink_pathForm_wrongSegmentCount_isNil() {
        // /room/<id>/extra → reject (path must be exactly /room/<id>)
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "https://ghostchat.one/room/rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_/extra")!))
    }

    func test_parse_noRoomParam_returnsNil() {
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "ghostchat://")!))
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "https://ghostchat.one/")!))
    }

    func test_parse_emptyRoomParam_returnsNil() {
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "https://ghostchat.one/?room=")!))
    }

    func test_parse_invalidRoomID_returnsNil() {
        // Short id — Room.isValidID rejects anything under minimum length.
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "ghostchat://?room=abc")!))
    }

    func test_parse_wrongHost_returnsNil() {
        // Not our domain.
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "https://evil.example.com/?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!))
    }

    func test_parse_fileScheme_returnsNil() {
        XCTAssertNil(DeepLinkRouter.parse(URL(string: "file:///tmp/?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!))
    }

    // MARK: - submit() + clear()

    func test_submit_storesParsedRoomId() {
        let router = DeepLinkRouter()
        router.submit(URL(string: "https://ghostchat.one/?room=rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")!)
        XCTAssertEqual(router.pendingRoomId, "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_")
    }

    func test_submit_invalidURL_doesNotOverwritePending() {
        let router = DeepLinkRouter()
        router.pendingRoomId = "prior-value"
        router.submit(URL(string: "https://evil.example.com/?room=foo")!)
        XCTAssertEqual(router.pendingRoomId, "prior-value")
    }

    func test_clear_nilsPending() {
        let router = DeepLinkRouter()
        router.pendingRoomId = "x"
        router.clear()
        XCTAssertNil(router.pendingRoomId)
    }
}
