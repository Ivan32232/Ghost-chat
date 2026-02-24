import XCTest
@testable import GhostChat

/// Тесты padding и моделей сообщений
final class MessageTests: XCTestCase {

    // MARK: - Padding

    func testPaddingFormat() throws {
        let crypto = GhostCrypto()
        let padded = try crypto.padMessage("hello")

        // Первые 4 символа — длина base64 сообщения
        let prefix = String(padded.prefix(4))
        let length = Int(prefix)!

        XCTAssertGreaterThan(length, 0)
        XCTAssertEqual(padded.count % 256, 0)
    }

    func testPaddingMessageTooLong() {
        let crypto = GhostCrypto()
        // base64 сообщения > 9999 символов
        let longMessage = String(repeating: "a", count: 10000)
        XCTAssertThrowsError(try crypto.padMessage(longMessage))
    }

    func testPaddingEmptyMessage() throws {
        let crypto = GhostCrypto()
        let padded = try crypto.padMessage("")
        let unpadded = try crypto.unpadMessage(padded)
        XCTAssertEqual(unpadded, "")
    }

    func testPaddingUnicode() throws {
        let crypto = GhostCrypto()
        let msg = "Привет 🇷🇺 мир 🌍"
        let padded = try crypto.padMessage(msg)
        let unpadded = try crypto.unpadMessage(padded)
        XCTAssertEqual(unpadded, msg)
    }

    // MARK: - ChatMessage Model

    func testMessageExpiry() {
        let msg = ChatMessage(text: "test", type: .sent, autoDeleteInterval: 0.1)
        XCTAssertFalse(msg.isExpired)

        // Wait for expiry
        let expectation = XCTestExpectation(description: "Message expires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(msg.isExpired)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testMessageRemainingTime() {
        let msg = ChatMessage(text: "test", type: .sent, autoDeleteInterval: 300)
        XCTAssertGreaterThan(msg.remainingTime, 290)
        XCTAssertLessThanOrEqual(msg.remainingTime, 300)
    }

    func testRemainingTimeFormatted() {
        let msg = ChatMessage(text: "test", type: .sent, autoDeleteInterval: 300)
        let formatted = msg.remainingTimeFormatted
        XCTAssertTrue(formatted.contains(":"))
    }

    // MARK: - ControlMessage

    func testControlMessageParsing() {
        let json: [String: Any] = ["type": "call-request"]
        let msg = ControlMessage.from(json)

        if case .callRequest = msg {
            // OK
        } else {
            XCTFail("Expected callRequest")
        }
    }

    func testControlMessageSerialization() {
        let msg = ControlMessage.callResponse(accepted: true)
        let json = msg.toJSON()

        XCTAssertEqual(json["type"] as? String, "call-response")
        XCTAssertEqual(json["accepted"] as? Bool, true)
    }

    func testControlMessageRoundtrip() {
        let original = ControlMessage.messageAck(counter: 42)
        let json = original.toJSON()
        let parsed = ControlMessage.from(json)

        if case .messageAck(let counter) = parsed {
            XCTAssertEqual(counter, 42)
        } else {
            XCTFail("Expected messageAck")
        }
    }
}
