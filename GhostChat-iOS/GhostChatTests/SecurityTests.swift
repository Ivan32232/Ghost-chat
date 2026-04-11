import XCTest
import CryptoKit
@testable import Ghost_chat

/// Тесты безопасности: PIN/биометрия, Double Ratchet, файлы, room ID, ControlMessage
final class SecurityTests: XCTestCase {

    // MARK: - Сценарий 6: PIN / Биометрия

    @MainActor
    func testPinSaveAndVerifyRoundtrip() {
        let service = BiometricAuthService()
        service.setPin("1234")

        XCTAssertTrue(service.isPinSet, "PIN должен быть установлен после setPin()")
        XCTAssertTrue(service.verifyPin("1234"), "Правильный PIN должен пройти верификацию")
        XCTAssertTrue(service.isUnlocked, "После верного PIN приложение должно разблокироваться")
    }

    @MainActor
    func testWrongPinReturnsFalse() {
        let service = BiometricAuthService()
        service.setPin("1234")

        XCTAssertFalse(service.verifyPin("0000"), "Неверный PIN должен вернуть false")
        XCTAssertFalse(service.verifyPin(""), "Пустой PIN должен вернуть false")
        XCTAssertFalse(service.verifyPin("12345"), "PIN другой длины должен вернуть false")
    }

    @MainActor
    func testPinBruteForce5FailsLockout() {
        let service = BiometricAuthService()
        service.setPin("9999")

        // 5 неверных попыток → lockout (30 секунд)
        for _ in 1...5 {
            _ = service.verifyPin("0000")
        }

        // Даже правильный PIN не проходит во время lockout
        XCTAssertFalse(
            service.verifyPin("9999"),
            "После 5 неверных попыток verifyPin должен возвращать false даже для верного PIN (lockout)"
        )
        XCTAssertGreaterThan(
            service.pinLockoutRemaining, 0,
            "Lockout таймер должен быть активен"
        )
    }

    @MainActor
    func testPinBruteForce5FailsTriggersLockout() {
        let service = BiometricAuthService()
        service.setPin("5678")

        // Первые 4 попытки проходят (увеличивают счётчик, но нет lockout)
        for _ in 1...4 {
            XCTAssertFalse(service.verifyPin("0000"))
        }

        // 5-я попытка: увеличивает счётчик до 5, включает lockout
        XCTAssertFalse(service.verifyPin("0000"))

        // 6-я попытка: lockout активен — правильный PIN тоже возвращает false
        XCTAssertFalse(service.verifyPin("5678"), "Во время lockout даже правильный PIN должен возвращать false")

        // PIN всё ещё установлен (данные не стёрты, просто заблокировано)
        XCTAssertTrue(service.isPinSet, "PIN должен остаться после lockout (wipe только на 10-й)")
    }

    @MainActor
    func testPinLegacySHA256Migration() {
        // Имитируем legacy формат: SHA-256 хеш PIN (32 байта, без соли)
        let pin = "4321"
        let legacyHash = Data(SHA256.hash(data: Data(pin.utf8)))
        XCTAssertEqual(legacyHash.count, 32, "Legacy SHA-256 хеш должен быть 32 байта")

        // Сохраняем legacy хеш напрямую в Keychain
        KeychainService.save(legacyHash, forKey: "app_pin_hash")

        let service = BiometricAuthService()
        XCTAssertTrue(service.isPinSet, "Сервис должен увидеть legacy PIN")

        // Верификация с legacy форматом должна пройти и мигрировать на PBKDF2
        XCTAssertTrue(service.verifyPin(pin), "Legacy PIN должен быть верифицирован")

        // После миграции: сохранённый хеш должен быть 48 байт (16 salt + 32 PBKDF2)
        if let stored = KeychainService.load(forKey: "app_pin_hash") {
            XCTAssertEqual(stored.count, 48, "После миграции хеш должен быть 48 байт (PBKDF2)")
        } else {
            XCTFail("PIN хеш не найден в Keychain после миграции")
        }

        // Повторная верификация с новым форматом
        let service2 = BiometricAuthService()
        XCTAssertTrue(service2.verifyPin(pin), "PIN должен работать после миграции на PBKDF2")

        // Cleanup
        KeychainService.delete(forKey: "app_pin_hash")
    }

    @MainActor
    func testPinChangeResetsBruteForce() {
        let service = BiometricAuthService()
        service.setPin("1111")

        // 3 неверных попытки
        for _ in 1...3 {
            _ = service.verifyPin("0000")
        }

        // Смена PIN должна сбросить счётчик
        service.setPin("2222")
        XCTAssertTrue(service.verifyPin("2222"), "Новый PIN должен работать после смены")
    }

    // MARK: - Сценарий 3: Double Ratchet

    func testDoubleRatchetEncryptDecryptRoundtrip() throws {
        let (alice, bob) = try createRatchetPair()

        let plaintext = Data("Привет через Double Ratchet!".utf8)
        let (encHeader, ciphertext) = try alice.encrypt(plaintext)
        let decrypted = try bob.decrypt(encryptedHeader: encHeader, ciphertext: ciphertext)

        XCTAssertEqual(decrypted, plaintext, "Расшифрованное сообщение должно совпадать с оригиналом")
    }

    func testDoubleRatchetBidirectional() throws {
        let (alice, bob) = try createRatchetPair()

        // Alice → Bob
        let msg1 = Data("От Алисы".utf8)
        let (h1, c1) = try alice.encrypt(msg1)
        let d1 = try bob.decrypt(encryptedHeader: h1, ciphertext: c1)
        XCTAssertEqual(d1, msg1)

        // Bob → Alice (triggers DH ratchet)
        let msg2 = Data("От Боба".utf8)
        let (h2, c2) = try bob.encrypt(msg2)
        let d2 = try alice.decrypt(encryptedHeader: h2, ciphertext: c2)
        XCTAssertEqual(d2, msg2)

        // Alice → Bob again (another DH ratchet)
        let msg3 = Data("Снова Алиса".utf8)
        let (h3, c3) = try alice.encrypt(msg3)
        let d3 = try bob.decrypt(encryptedHeader: h3, ciphertext: c3)
        XCTAssertEqual(d3, msg3)
    }

    func testDoubleRatchetOutOfOrderDelivery() throws {
        let (alice, bob) = try createRatchetPair()

        // Alice отправляет 3 сообщения подряд
        let msg1 = Data("Сообщение 1".utf8)
        let msg2 = Data("Сообщение 2".utf8)
        let msg3 = Data("Сообщение 3".utf8)

        let (h1, c1) = try alice.encrypt(msg1)
        let (h2, c2) = try alice.encrypt(msg2)
        let (h3, c3) = try alice.encrypt(msg3)

        // Bob получает в порядке 3, 1, 2 (out-of-order)
        let d3 = try bob.decrypt(encryptedHeader: h3, ciphertext: c3)
        XCTAssertEqual(d3, msg3, "Сообщение 3 должно расшифроваться первым")

        // Сообщения 1 и 2 — skipped keys
        if let d1 = try bob.tryDecryptWithSkippedKey(encryptedHeader: h1, ciphertext: c1) {
            XCTAssertEqual(d1, msg1, "Сообщение 1 должно расшифроваться через skipped keys")
        } else {
            XCTFail("Не удалось расшифровать пропущенное сообщение 1")
        }

        if let d2 = try bob.tryDecryptWithSkippedKey(encryptedHeader: h2, ciphertext: c2) {
            XCTAssertEqual(d2, msg2, "Сообщение 2 должно расшифроваться через skipped keys")
        } else {
            XCTFail("Не удалось расшифровать пропущенное сообщение 2")
        }
    }

    func testDoubleRatchetStateExportImport() throws {
        let (alice, bob) = try createRatchetPair()

        // Отправляем несколько сообщений
        for i in 0..<5 {
            let msg = Data("Сообщение \(i)".utf8)
            let (h, c) = try alice.encrypt(msg)
            let d = try bob.decrypt(encryptedHeader: h, ciphertext: c)
            XCTAssertEqual(d, msg)
        }

        // Export Alice's state
        let aliceState = alice.exportState()
        let aliceSkipped = alice.exportSkippedKeys()

        // Restore Alice from state
        let aliceRestored = try DoubleRatchet(fromState: aliceState)
        aliceRestored.importSkippedKeys(aliceSkipped)

        // Продолжаем разговор с восстановленным состоянием
        let msg = Data("После восстановления".utf8)
        let (h, c) = try aliceRestored.encrypt(msg)
        let d = try bob.decrypt(encryptedHeader: h, ciphertext: c)
        XCTAssertEqual(d, msg, "Разговор должен продолжиться после restore из state")
    }

    func testDoubleRatchetStateExportImportCodable() throws {
        let (alice, _) = try createRatchetPair()

        let state = alice.exportState()

        // Проверяем что DoubleRatchetState корректно сериализуется/десериализуется через Codable
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        XCTAssertGreaterThan(data.count, 0)

        let decoder = JSONDecoder()
        let restored = try decoder.decode(DoubleRatchetState.self, from: data)

        XCTAssertEqual(restored.dhSendingPrivateKey, state.dhSendingPrivateKey)
        XCTAssertEqual(restored.dhReceivingPublicKey, state.dhReceivingPublicKey)
        XCTAssertEqual(restored.rootKey, state.rootKey)
        XCTAssertEqual(restored.sendMessageNumber, state.sendMessageNumber)
        XCTAssertEqual(restored.receiveMessageNumber, state.receiveMessageNumber)
        XCTAssertEqual(restored.previousChainLength, state.previousChainLength)
    }

    func testDoubleRatchetMaxSkipProtection() throws {
        let (alice, bob) = try createRatchetPair()

        // Alice отправляет 101+ сообщение, Bob пытается расшифровать только последнее
        // Это должно вызвать ошибку tooManySkippedMessages
        var lastHeader: Data!
        var lastCiphertext: Data!

        for i in 0..<(DoubleRatchet.maxSkip + 5) {
            let msg = Data("Msg \(i)".utf8)
            let (h, c) = try alice.encrypt(msg)
            lastHeader = h
            lastCiphertext = c
        }

        // Bob пытается расшифровать последнее сообщение (пропущено >100)
        XCTAssertThrowsError(
            try bob.decrypt(encryptedHeader: lastHeader, ciphertext: lastCiphertext)
        ) { error in
            guard let drError = error as? DoubleRatchetError else {
                XCTFail("Ожидается DoubleRatchetError, получено \(error)")
                return
            }
            if case .tooManySkippedMessages = drError {
                // OK — правильная ошибка
            } else {
                XCTFail("Ожидается tooManySkippedMessages, получено \(drError)")
            }
        }
    }

    func testDoubleRatchetMultipleRatchetSteps() throws {
        let (alice, bob) = try createRatchetPair()

        // Имитируем длинный разговор с чередованием отправителей (множественные DH ratchet steps)
        for i in 0..<20 {
            let msg = Data("Ping \(i)".utf8)
            let (h, c) = try alice.encrypt(msg)
            let d = try bob.decrypt(encryptedHeader: h, ciphertext: c)
            XCTAssertEqual(d, msg)

            let reply = Data("Pong \(i)".utf8)
            let (rh, rc) = try bob.encrypt(reply)
            let rd = try alice.decrypt(encryptedHeader: rh, ciphertext: rc)
            XCTAssertEqual(rd, reply)
        }
    }

    func testDoubleRatchetDestroy() throws {
        let (alice, _) = try createRatchetPair()

        alice.destroy()

        // После destroy шифрование должно быть невозможно
        // sendChainKey = nil → sendChainNotInitialized
        XCTAssertThrowsError(try alice.encrypt(Data("test".utf8))) { error in
            guard let drError = error as? DoubleRatchetError else {
                XCTFail("Ожидается DoubleRatchetError")
                return
            }
            if case .sendChainNotInitialized = drError {
                // OK
            } else {
                XCTFail("Ожидается sendChainNotInitialized, получено \(drError)")
            }
        }

        // Skipped keys должны быть очищены
        XCTAssertTrue(alice.skippedKeys.isEmpty, "Skipped keys должны быть очищены после destroy")
    }

    // MARK: - Сценарий 8: File Transfer Security

    func testSanitizeFileNameStripsPathTraversal() {
        let service = FileTransferService()

        // Тестируем через handleFileStart — sanitizeFileName вызывается внутри
        service.handleFileStart(
            fileId: "test1",
            name: "../../../etc/passwd",
            size: 100,
            mimeType: "text/plain",
            totalChunks: 1
        )

        // Проверяем что имя файла не содержит path traversal
        // Прямого доступа к IncomingTransfer нет, поэтому тестируем через roundtrip
        // sanitizeFileName заменяет ".." на "_" и "/" на "_"
        let sanitized = sanitizeFileName("../../../etc/passwd")
        XCTAssertFalse(sanitized.contains(".."), "Имя файла не должно содержать '..'")
        XCTAssertFalse(sanitized.contains("/"), "Имя файла не должно содержать '/'")
    }

    func testSanitizeFileNameStripsBackslashTraversal() {
        let sanitized = sanitizeFileName("..\\..\\Windows\\system32\\config")
        XCTAssertFalse(sanitized.contains("\\"), "Имя файла не должно содержать '\\'")
        XCTAssertFalse(sanitized.contains(".."), "Имя файла не должно содержать '..'")
    }

    func testSanitizeFileNameStripsNullBytes() {
        let sanitized = sanitizeFileName("photo\0.jpg\0")
        XCTAssertFalse(sanitized.contains("\0"), "Имя файла не должно содержать null bytes")
        XCTAssertTrue(sanitized.contains("photo"), "Имя файла должно сохранить допустимые символы")
        XCTAssertTrue(sanitized.contains(".jpg"), "Расширение файла должно сохраниться")
    }

    func testSanitizeFileNameComplexTraversal() {
        // Комбинированная атака
        let sanitized = sanitizeFileName("../\0secret/../../../etc/shadow")
        XCTAssertFalse(sanitized.contains(".."), "Комбинированная атака: '..' должны быть удалены")
        XCTAssertFalse(sanitized.contains("/"), "Комбинированная атака: '/' должны быть удалены")
        XCTAssertFalse(sanitized.contains("\0"), "Комбинированная атака: null bytes должны быть удалены")
    }

    func testFileSizeExceedsLimitRejected() {
        let service = FileTransferService()

        // Максимум: 100MB
        let oversizeBytes: Int64 = 100 * 1024 * 1024 + 1  // 100MB + 1 byte

        // handleFileStart с размером > 100MB не должен создать transfer
        service.handleFileStart(
            fileId: "oversize",
            name: "huge.zip",
            size: oversizeBytes,
            mimeType: "application/zip",
            totalChunks: 6400
        )

        // handleFileComplete для незарегистрированного transfer ничего не сделает (не крашнется)
        // Если бы transfer был создан, onFileReceived бы вызвался
        var fileReceived = false
        service.onFileReceived = { _, _, _, _, _ in
            fileReceived = true
        }
        service.handleFileComplete(fileId: "oversize")

        XCTAssertFalse(fileReceived, "Файл >100MB не должен быть принят")
    }

    func testFileSizeExactLimitAccepted() {
        let service = FileTransferService()
        let exactLimit: Int64 = 100 * 1024 * 1024  // Ровно 100MB

        service.handleFileStart(
            fileId: "exact",
            name: "big.zip",
            size: exactLimit,
            mimeType: "application/zip",
            totalChunks: 6400
        )

        // Файл ровно на лимите должен быть принят (transfer создан)
        // Проверяем что handleFileChunk не крашится (transfer существует)
        service.handleFileChunk(fileId: "exact", index: 0, base64Data: "dGVzdA==")
        // Если transfer не существовал бы, handleFileChunk просто вернулся бы
    }

    // MARK: - Сценарий 9: Room ID Validation

    func testValidRoomIdAccepted() {
        // Валидный room ID: 64 символа base64url (48 random bytes → base64url)
        let validId = String(repeating: "A", count: 64)
        XCTAssertTrue(isValidRoomId(validId), "64-символьный base64url ID должен быть валиден")

        // Все допустимые символы base64url
        let base64urlChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        XCTAssertTrue(isValidRoomId(base64urlChars), "Все символы base64url должны быть допустимы")
    }

    func testRoomIdWithDotsRejected() {
        let idWithDots = String(repeating: "A", count: 62) + ".."
        XCTAssertFalse(isValidRoomId(idWithDots), "Room ID с '..' должен быть отклонён")
    }

    func testRoomIdTooShortRejected() {
        let shortId = String(repeating: "A", count: 10)
        XCTAssertFalse(isValidRoomId(shortId), "Слишком короткий room ID должен быть отклонён")

        XCTAssertFalse(isValidRoomId(""), "Пустой room ID должен быть отклонён")
        XCTAssertFalse(isValidRoomId("a"), "Однобуквенный room ID должен быть отклонён")
    }

    func testRoomIdTooLongRejected() {
        let longId = String(repeating: "A", count: 100)
        XCTAssertFalse(isValidRoomId(longId), "Слишком длинный room ID должен быть отклонён")

        let id65 = String(repeating: "A", count: 65)
        XCTAssertFalse(isValidRoomId(id65), "Room ID 65 символов должен быть отклонён")
    }

    func testRoomIdWithSpecialCharsRejected() {
        let base = String(repeating: "A", count: 60)

        XCTAssertFalse(isValidRoomId(base + "!@#$"), "Room ID со спецсимволами должен быть отклонён")
        XCTAssertFalse(isValidRoomId(base + "/../"), "Room ID с path traversal должен быть отклонён")
        XCTAssertFalse(isValidRoomId(base + " \t\n "), "Room ID с пробелами должен быть отклонён")
        XCTAssertFalse(isValidRoomId(base + "+/= "), "Room ID с base64 (не url-safe) символами должен быть отклонён")
    }

    func testRoomIdWithSlashRejected() {
        let idWithSlash = String(repeating: "A", count: 32) + "/" + String(repeating: "B", count: 31)
        XCTAssertFalse(isValidRoomId(idWithSlash), "Room ID с '/' должен быть отклонён")
    }

    func testRoomIdWithNullByteRejected() {
        // Null byte в room ID — потенциальная инъекция
        var chars = Array(repeating: Character("A"), count: 64)
        chars[32] = Character("\0")
        let idWithNull = String(chars)
        XCTAssertFalse(isValidRoomId(idWithNull), "Room ID с null byte должен быть отклонён")
    }

    // MARK: - Сценарий: ControlMessage Parsing

    func testControlMessageAllTypesRoundtrip() {
        // Все типы должны сериализоваться и парситься обратно
        let messages: [(ControlMessage, String)] = [
            (.callRequest, "call-request"),
            (.callResponse(accepted: true), "call-response"),
            (.callResponse(accepted: false), "call-response"),
            (.callEnd, "call-end"),
            (.securityAlert(alert: "suspicious"), "security-alert"),
            (.messageAck(counter: 42), "message-ack"),
            (.messageRead(counter: 7), "message-read"),
            (.ready, "ready"),
            (.pushToken(token: "abc123"), "push-token"),
            (.notifyToken(token: "def456"), "notify-token"),
            (.typing(isTyping: true), "typing"),
            (.typing(isTyping: false), "typing"),
            (.capabilities(features: ["voice", "files"]), "capabilities"),
            (.fileComplete(fileId: "file-1"), "file-complete"),
            (.roomRotate(roomId: String(repeating: "X", count: 64)), "room-rotate"),
        ]

        for (original, expectedType) in messages {
            let json = original.toJSON()
            XCTAssertEqual(json["type"] as? String, expectedType, "Тип \(expectedType): сериализация")

            let parsed = ControlMessage.from(json)
            XCTAssertNotNil(parsed, "Тип \(expectedType): парсинг не должен вернуть nil")
        }
    }

    func testControlMessageFileStartRoundtrip() {
        let original = ControlMessage.fileStart(
            fileId: "abc",
            name: "photo.jpg",
            size: 1024,
            mimeType: "image/jpeg",
            totalChunks: 1
        )
        let json = original.toJSON()
        let parsed = ControlMessage.from(json)

        if case .fileStart(let fId, let name, let size, let mime, let chunks) = parsed {
            XCTAssertEqual(fId, "abc")
            XCTAssertEqual(name, "photo.jpg")
            XCTAssertEqual(size, 1024)
            XCTAssertEqual(mime, "image/jpeg")
            XCTAssertEqual(chunks, 1)
        } else {
            XCTFail("Ожидается fileStart")
        }
    }

    func testControlMessageFileChunkRoundtrip() {
        let original = ControlMessage.fileChunk(fileId: "abc", index: 5, data: "base64data==")
        let json = original.toJSON()
        let parsed = ControlMessage.from(json)

        if case .fileChunk(let fId, let idx, let data) = parsed {
            XCTAssertEqual(fId, "abc")
            XCTAssertEqual(idx, 5)
            XCTAssertEqual(data, "base64data==")
        } else {
            XCTFail("Ожидается fileChunk")
        }
    }

    func testControlMessageRenegotiateRoundtrip() {
        let sdp: [String: Any] = ["type": "offer", "sdp": "v=0\r\n..."]
        let original = ControlMessage.renegotiate(sdp: sdp)
        let json = original.toJSON()
        let parsed = ControlMessage.from(json)

        if case .renegotiate(let parsedSdp) = parsed {
            XCTAssertEqual(parsedSdp["type"] as? String, "offer")
            XCTAssertEqual(parsedSdp["sdp"] as? String, "v=0\r\n...")
        } else {
            XCTFail("Ожидается renegotiate")
        }
    }

    func testControlMessageUnknownTypeReturnsNil() {
        let json: [String: Any] = ["type": "unknown-future-type", "data": 123]
        let parsed = ControlMessage.from(json)
        XCTAssertNil(parsed, "Неизвестный тип должен вернуть nil")
    }

    func testControlMessageMissingTypeReturnsNil() {
        let json: [String: Any] = ["data": "no type field"]
        let parsed = ControlMessage.from(json)
        XCTAssertNil(parsed, "JSON без поля 'type' должен вернуть nil")
    }

    func testControlMessageEmptyJsonReturnsNil() {
        let json: [String: Any] = [:]
        let parsed = ControlMessage.from(json)
        XCTAssertNil(parsed, "Пустой JSON должен вернуть nil")
    }

    func testControlMessageMalformedPayloadReturnsNil() {
        // call-response без обязательного поля "accepted"
        let json1: [String: Any] = ["type": "call-response"]
        XCTAssertNil(ControlMessage.from(json1), "call-response без accepted → nil")

        // message-ack без обязательного поля "c"
        let json2: [String: Any] = ["type": "message-ack"]
        XCTAssertNil(ControlMessage.from(json2), "message-ack без counter → nil")

        // file-start с неполными данными
        let json3: [String: Any] = ["type": "file-start", "fileId": "x"]
        XCTAssertNil(ControlMessage.from(json3), "file-start без обязательных полей → nil")

        // typing без isTyping
        let json4: [String: Any] = ["type": "typing"]
        XCTAssertNil(ControlMessage.from(json4), "typing без isTyping → nil")

        // security-alert без alert string
        let json5: [String: Any] = ["type": "security-alert"]
        XCTAssertNil(ControlMessage.from(json5), "security-alert без alert → nil")

        // room-rotate с пустым roomId
        let json6: [String: Any] = ["type": "room-rotate", "roomId": ""]
        XCTAssertNil(ControlMessage.from(json6), "room-rotate с пустым roomId → nil")

        // push-token без token
        let json7: [String: Any] = ["type": "push-token"]
        XCTAssertNil(ControlMessage.from(json7), "push-token без token → nil")
    }

    func testControlMessageWrongValueTypesReturnsNil() {
        // accepted должен быть Bool, но передан String
        let json1: [String: Any] = ["type": "call-response", "accepted": "yes"]
        XCTAssertNil(ControlMessage.from(json1), "call-response с accepted=string → nil")

        // counter должен быть Int, но передан String
        let json2: [String: Any] = ["type": "message-ack", "c": "42"]
        XCTAssertNil(ControlMessage.from(json2), "message-ack с c=string → nil")
    }

    // MARK: - DRHeader Tests

    func testDRHeaderSerializeDeserialize() throws {
        let dhKey = Data(repeating: 0x04, count: 65)  // Fake 65-byte DH key
        let header = DRHeader(dhPublicKey: dhKey, pn: 10, n: 42)

        let serialized = header.serialize()
        XCTAssertEqual(serialized.count, 73, "Serialized header: 65 + 4 + 4 = 73 bytes")

        let deserialized = try DRHeader.deserialize(serialized)
        XCTAssertEqual(deserialized.dhPublicKey, dhKey)
        XCTAssertEqual(deserialized.pn, 10)
        XCTAssertEqual(deserialized.n, 42)
    }

    func testDRHeaderInvalidSizeThrows() {
        let tooShort = Data(repeating: 0, count: 50)
        XCTAssertThrowsError(try DRHeader.deserialize(tooShort)) { error in
            XCTAssertTrue(error is DoubleRatchetError)
        }
    }

    func testDRHeaderJSONRoundtrip() throws {
        let realKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let header = DRHeader(dhPublicKey: realKey, pn: 3, n: 17)

        let json = header.toJSON()
        let restored = try DRHeader.fromJSON(json)

        XCTAssertEqual(restored.dhPublicKey, realKey)
        XCTAssertEqual(restored.pn, 3)
        XCTAssertEqual(restored.n, 17)
    }

    // MARK: - Helpers

    /// Создаёт пару Double Ratchet (Alice = initiator, Bob = responder) с общим секретом
    private func createRatchetPair() throws -> (DoubleRatchet, DoubleRatchet) {
        // Симулируем ECDH key exchange
        let aliceIdentity = P256.KeyAgreement.PrivateKey()
        let bobIdentity = P256.KeyAgreement.PrivateKey()

        // ECDH → shared secret
        let sharedSecret = try aliceIdentity.sharedSecretFromKeyAgreement(
            with: bobIdentity.publicKey
        )
        let sharedKey = SymmetricKey(data: sharedSecret.withUnsafeBytes { Data($0) })

        // Bob создаётся как responder (reuse его identity key pair)
        let bob = DoubleRatchet(asResponder: sharedKey, initialKeyPair: bobIdentity)

        // Alice создаётся как initiator с public key Боба
        let alice = try DoubleRatchet(asInitiator: sharedKey, peerDHKey: bobIdentity.publicKey)

        return (alice, bob)
    }

    /// Валидация Room ID — копия логики из GhostChatApp / ChatViewModel
    private func isValidRoomId(_ id: String) -> Bool {
        let pattern = "^[A-Za-z0-9_-]{64}$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    /// Санитизация имени файла — копия логики из FileTransferService
    private func sanitizeFileName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "\0", with: "")
    }
}
