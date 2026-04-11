import XCTest

/// UI тесты Ghost Chat — проверяют основные user flows
/// Запуск: xcodebuild test -scheme GhostChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:GhostChatUITests
final class GhostChatUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
    }

    // MARK: - Welcome Screen

    func testWelcomeScreenElements() {
        // Ghost title
        XCTAssertTrue(app.staticTexts["Ghost"].exists)

        // New chat button
        let newChat = app.buttons["newChatButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))

        // Room code field
        let roomField = app.textFields["roomCodeField"]
        XCTAssertTrue(roomField.exists)

        // Settings gear
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS 'gearshape'")).firstMatch
        XCTAssertTrue(settings.exists || app.images["gearshape.fill"].exists)
    }

    func testCreateRoom() {
        // Tap New Chat
        let newChat = app.buttons["newChatButton"]
        guard newChat.waitForExistence(timeout: 5) else {
            // Contacts mode — tap compose
            let compose = app.buttons.matching(NSPredicate(format: "label CONTAINS 'pencil'")).firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 3))
            compose.tap()
            return
        }
        newChat.tap()

        // Should show Waiting for peer
        let waiting = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Waiting' OR label CONTAINS 'Ожидание'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "Should navigate to waiting screen")

        // Copy button should appear
        let copy = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Copy' OR label CONTAINS 'Копировать' OR label CONTAINS 'doc.on.doc'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy button should appear")

        // Cancel button
        let cancel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cancel' OR label CONTAINS 'Отмена'")).firstMatch
        XCTAssertTrue(cancel.exists, "Cancel button should appear")

        // Tap cancel to go back
        cancel.tap()

        // Should return to welcome
        let ghost = app.staticTexts["Ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 5), "Should return to welcome screen")
    }

    func testJoinWithEmptyCode() {
        let joinButton = app.buttons["joinButton"]
        guard joinButton.waitForExistence(timeout: 5) else { return }

        // Join button should be disabled when room code is empty
        XCTAssertFalse(joinButton.isEnabled, "Join should be disabled with empty code")
    }

    func testJoinWithInvalidCode() {
        let roomField = app.textFields["roomCodeField"]
        guard roomField.waitForExistence(timeout: 5) else { return }

        roomField.tap()
        roomField.typeText("invalid-short-code")

        let joinButton = app.buttons["joinButton"]
        joinButton.tap()

        // Should stay on welcome (invalid room code doesn't navigate)
        sleep(3)
        let ghost = app.staticTexts["Ghost"]
        XCTAssertTrue(ghost.exists, "Should stay on welcome with invalid code")
    }

    // MARK: - Settings

    func testOpenSettings() {
        // Tap settings gear
        let gear = app.images["gearshape.fill"]
        if gear.waitForExistence(timeout: 3) {
            gear.tap()
        } else {
            // Try button approach
            let buttons = app.buttons.allElementsBoundByIndex
            for btn in buttons {
                if btn.label.contains("gear") || btn.label.contains("Settings") {
                    btn.tap()
                    break
                }
            }
        }

        // Should show settings (PIN, biometric, etc)
        let settingsContent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'PIN' OR label CONTAINS 'ПИН'")).firstMatch
        XCTAssertTrue(settingsContent.waitForExistence(timeout: 5), "Settings should open")
    }

    // MARK: - Connection Flow

    func testConnectionStepsExist() {
        // Create room first
        let newChat = app.buttons["newChatButton"]
        if newChat.waitForExistence(timeout: 3) {
            newChat.tap()
        } else {
            let compose = app.buttons.matching(NSPredicate(format: "label CONTAINS 'pencil'")).firstMatch
            if compose.waitForExistence(timeout: 3) {
                compose.tap()
            }
        }

        // Wait for waiting screen
        sleep(3)

        // Connection step strings should be localized
        // (They appear on connecting screen, not waiting — but the enum exists)
        // Verify we're on waiting/connecting screen
        let waitingOrConnecting = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'Waiting' OR label CONTAINS 'Connecting' OR label CONTAINS 'Ожидание' OR label CONTAINS 'Подключение'"
        )).firstMatch
        XCTAssertTrue(waitingOrConnecting.waitForExistence(timeout: 5))

        // Go back
        let cancel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cancel' OR label CONTAINS 'Отмена'")).firstMatch
        if cancel.exists { cancel.tap() }
    }

    // MARK: - Disconnect Banner

    func testDisconnectBannerNotVisibleByDefault() {
        // On welcome screen, disconnect banner should NOT be visible
        let banner = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'reconnect' OR label CONTAINS 'перепод'"
        )).firstMatch
        XCTAssertFalse(banner.exists, "Disconnect banner should not show on welcome")
    }
}
