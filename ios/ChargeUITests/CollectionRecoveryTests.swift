import XCTest

final class CollectionRecoveryTests: XCTestCase {
    func testSettingsHideProviderClearsWarningsAndSelectedTab() {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-collection-failures", "5", "-charge-demo-second-device",
                               "-charge-demo-latency", "2.5",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        restoreClaudeIfHidden(app)
        XCTAssertTrue(app.buttons["hideProvider-claude"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["Claude"].tap()

        app.buttons["settingsButton"].tap()
        let toggle = app.switches["providerToggle-claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["settingsDone"].tap()

        // These local UI changes must not wait for the delayed cloud refresh.
        XCTAssertFalse(app.segmentedControls.buttons["Claude"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["All"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["Codex"].exists)
        XCTAssertFalse(app.buttons["hideProvider-claude"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["collectionIssue-demo-device-claude"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["collectionIssue-demo-second-claude"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Claude disabled in provider settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        restoreClaudeIfHidden(app)
        XCTAssertTrue(app.buttons["hideProvider-claude"].waitForExistence(timeout: 10))
    }

    func testAnotherHealthyDeviceDoesNotSuggestHiding() {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-collection-failures", "5", "-charge-demo-healthy-second-device",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        restoreClaudeIfHidden(app)
        XCTAssertTrue(app.staticTexts["Another PC is reporting this provider normally. Check the PC shown above."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["hideProvider-claude"].exists)
    }

    func testDetectedClaudeWithoutUsageCardShowsSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-collection-failures", "1",
                               "-charge-demo-collection-reason", "error:credentials_missing", "-charge-demo-no-claude-card",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        restoreClaudeIfHidden(app)
        XCTAssertTrue(app.staticTexts["Check Claude setup on this PC"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["hideProvider-claude"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["Claude"].exists)
    }

    func testPersistentFailureCanBeHiddenAcrossDevicesAndRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-collection-failures", "5", "-charge-demo-second-device",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        restoreClaudeIfHidden(app)

        let hide = app.buttons["hideProvider-claude"]
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "hideProvider-claude").count, 1)
        XCTAssertTrue(app.staticTexts["5 consecutive attempts failed over at least 20 minutes."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Persistent Claude usage failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        hide.tap()
        XCTAssertFalse(hide.exists)
        XCTAssertFalse(app.descendants(matching: .any)["collectionIssue-demo-device-claude"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["collectionIssue-demo-second-claude"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["Claude"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Codex"].exists)

        // Hiding survives app restarts and is reversible from the existing setting.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(hide.exists)
        restoreClaudeIfHidden(app)
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
    }

    func testFourFailuresDoNotSuggestRemoval() {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-collection-failures", "4",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        restoreClaudeIfHidden(app)
        XCTAssertTrue(app.staticTexts["Retrying Claude usage"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["hideProvider-claude"].exists)
    }

    private func restoreClaudeIfHidden(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["providerToggle-claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" {
            // SwiftUI exposes the entire Form row as a switch. Tap its control,
            // rather than the label in the middle of the row.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        app.buttons["settingsDone"].tap()
    }
}
