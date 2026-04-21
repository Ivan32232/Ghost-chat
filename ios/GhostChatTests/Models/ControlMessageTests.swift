import XCTest
@testable import GhostChat

final class ControlMessageTests: XCTestCase {

    private func roundTrip(_ msg: ControlMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        XCTAssertEqual(msg, decoded, "roundtrip failed for \(msg)", file: file, line: line)
    }

    private func jsonObject(_ msg: ControlMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(msg)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Roundtrip per case (19 cases)

    func test_renegotiate() throws { try roundTrip(.renegotiate(sdp: "v=0\r\no=-...\r\n")) }
    func test_callRequest() throws { try roundTrip(.callRequest) }
    func test_callResponse_accept() throws { try roundTrip(.callResponse(accepted: true)) }
    func test_callResponse_decline() throws { try roundTrip(.callResponse(accepted: false)) }
    func test_callEnd() throws { try roundTrip(.callEnd) }
    func test_securityAlert() throws { try roundTrip(.securityAlert(alert: "screenshot")) }
    func test_messageAck() throws { try roundTrip(.messageAck(counter: 100)) }
    func test_messageRead() throws { try roundTrip(.messageRead(counter: 100)) }
    func test_ready() throws { try roundTrip(.ready) }
    func test_pushToken() throws { try roundTrip(.pushToken(token: "abcdef")) }
    func test_notifyToken() throws { try roundTrip(.notifyToken(token: "abcdef")) }
    func test_typing() throws { try roundTrip(.typing(isTyping: true)) }
    func test_capabilities() throws { try roundTrip(.capabilities(features: ["file", "voice", "pq"])) }
    func test_fileStart() throws { try roundTrip(.fileStart(fileId: "fid", name: "a.jpg", size: 1024, mimeType: "image/jpeg", totalChunks: 1)) }
    func test_fileChunk() throws { try roundTrip(.fileChunk(fileId: "fid", index: 0, data: "base64data==")) }
    func test_fileComplete() throws { try roundTrip(.fileComplete(fileId: "fid", sha256: String(repeating: "a", count: 64))) }
    func test_fileRetransmit() throws { try roundTrip(.fileRetransmit(fileId: "fid", indices: [1, 3, 5])) }
    func test_messageDelete() throws { try roundTrip(.messageDelete(messageId: "m1")) }
    func test_messageEdit() throws { try roundTrip(.messageEdit(messageId: "m1", newText: "edited")) }
    func test_messagePin() throws { try roundTrip(.messagePin(messageId: "m1", pinned: true)) }

    // MARK: - Wire format assertions

    func test_wireFormat_hasCtrlMarker() throws {
        let json = try jsonObject(.ready)
        XCTAssertEqual(json["_ctrl"] as? Bool, true)
        XCTAssertEqual(json["type"] as? String, "ready")
    }

    func test_wireFormat_usesSpecTypeStrings() throws {
        XCTAssertEqual(try jsonObject(.callRequest)["type"] as? String, "call-request")
        XCTAssertEqual(try jsonObject(.callResponse(accepted: true))["type"] as? String, "call-response")
        XCTAssertEqual(try jsonObject(.callEnd)["type"] as? String, "call-end")
        XCTAssertEqual(try jsonObject(.securityAlert(alert: "x"))["type"] as? String, "security-alert")
        XCTAssertEqual(try jsonObject(.messageAck(counter: 0))["type"] as? String, "message-ack")
        XCTAssertEqual(try jsonObject(.messageRead(counter: 0))["type"] as? String, "message-read")
        XCTAssertEqual(try jsonObject(.pushToken(token: "x"))["type"] as? String, "push-token")
        XCTAssertEqual(try jsonObject(.notifyToken(token: "x"))["type"] as? String, "notify-token")
        XCTAssertEqual(try jsonObject(.fileStart(fileId: "f", name: "n", size: 0, mimeType: "x", totalChunks: 1))["type"] as? String, "file-start")
        XCTAssertEqual(try jsonObject(.fileChunk(fileId: "f", index: 0, data: ""))["type"] as? String, "file-chunk")
        XCTAssertEqual(try jsonObject(.fileComplete(fileId: "f", sha256: String(repeating: "0", count: 64)))["type"] as? String, "file-complete")
        XCTAssertEqual(try jsonObject(.fileRetransmit(fileId: "f", indices: []))["type"] as? String, "file-retransmit")
        XCTAssertEqual(try jsonObject(.messageDelete(messageId: "m"))["type"] as? String, "message-delete")
        XCTAssertEqual(try jsonObject(.messageEdit(messageId: "m", newText: ""))["type"] as? String, "message-edit")
        XCTAssertEqual(try jsonObject(.messagePin(messageId: "m", pinned: false))["type"] as? String, "message-pin")
    }

    func test_messageAck_usesSingleLetterCounterKey() throws {
        let json = try jsonObject(.messageAck(counter: 7))
        XCTAssertEqual(json["c"] as? Int, 7)
        XCTAssertNil(json["counter"])
    }

    func test_fileComplete_carriesHexSha256() throws {
        let hex = "deadbeefcafebabefeedfacec0ffee00112233445566778899aabbccddeeff00"
        let json = try jsonObject(.fileComplete(fileId: "f", sha256: hex))
        XCTAssertEqual(json["fileId"] as? String, "f")
        XCTAssertEqual(json["sha256"] as? String, hex)
    }

    // MARK: - Error paths

    func test_decode_rejectsMissingCtrlMarker() {
        let bad = #"{"type":"ready"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ControlMessage.self, from: bad)) { err in
            if case ControlMessage.DecodingError.missingCtrlMarker = err { return }
            XCTFail("expected missingCtrlMarker, got \(err)")
        }
    }

    func test_decode_rejectsUnknownType() {
        let bad = #"{"_ctrl":true,"type":"bogus"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ControlMessage.self, from: bad)) { err in
            if case ControlMessage.DecodingError.unknownType(let t) = err {
                XCTAssertEqual(t, "bogus")
                return
            }
            XCTFail("expected unknownType, got \(err)")
        }
    }
}
