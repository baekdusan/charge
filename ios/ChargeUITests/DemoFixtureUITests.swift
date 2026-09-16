import XCTest

/// 데모 픽스처 인자로 띄운 화면 확인: 스트릭 보호, 값 미상 게이지, Claude 로그인 만료 즉시 안내.
/// 스크린샷을 결과 번들에 남겨 눈으로도 확인할 수 있게 한다.
final class DemoFixtureUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo"] + extra + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        showClaudeIfHidden(app)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testQuotaProtectionShowsProtectedStreakOnClaudeTab() {
        let app = launch(["-charge-demo-quota-protection"])
        let claudeTab = app.segmentedControls.buttons["Claude"]
        XCTAssertTrue(claudeTab.waitForExistence(timeout: 10))
        claudeTab.tap()
        XCTAssertTrue(app.staticTexts["Streak protected today"].waitForExistence(timeout: 10))
        app.swipeUp()
        attach(app, "Streak protected today (Claude tab)")
    }

    func testDefaultDemoHasNoProtectedStreak() {
        let app = launch([])
        let claudeTab = app.segmentedControls.buttons["Claude"]
        XCTAssertTrue(claudeTab.waitForExistence(timeout: 10))
        claudeTab.tap()
        XCTAssertTrue(app.staticTexts["Streak"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Streak protected today"].exists)
        XCTAssertFalse(app.staticTexts["No recent data"].exists)
        // 신선한 주간 62%는 소진 예측을 그린다(묵은 스냅샷 테스트의 "없음" 확인이 헛돌지 않는다는 근거)
        XCTAssertTrue(app.staticTexts.matching(Self.paceLine).firstMatch.waitForExistence(timeout: 10))
    }

    func testStaleClaudeShowsUnknownSessionGauge() {
        let app = launch(["-charge-demo-stale-claude"])
        XCTAssertTrue(app.staticTexts["No recent data"].waitForExistence(timeout: 10))
        // Claude 탭만 본다(Codex 카드는 신선해서 기존대로 소진 예측을 그린다)
        let claudeTab = app.segmentedControls.buttons["Claude"]
        XCTAssertTrue(claudeTab.waitForExistence(timeout: 10))
        claudeTab.tap()
        XCTAssertTrue(app.staticTexts["No recent data"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(Self.paceLine).firstMatch.exists, "묵은 주간 숫자 옆에 소진 예측을 그리지 않는다")
        attach(app, "Stale Claude snapshot with unknown session gauge")
    }

    private static let paceLine = NSPredicate(format: "label CONTAINS %@", "On pace to run out")

    func testExpiredClaudeSignInNeedsAttentionWithoutThreshold() {
        let app = launch(["-charge-demo-collection-failures", "1", "-charge-demo-collection-reason", "auth_expired"])
        XCTAssertTrue(app.staticTexts["Claude usage needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Open Claude Code on this PC once"].exists)
        XCTAssertFalse(app.staticTexts["Retrying Claude usage"].exists)
        // 복구 카드(숨기기 제안)의 5회, 20분 문턱은 그대로다
        XCTAssertFalse(app.buttons["hideProvider-claude"].exists)
        attach(app, "Expired Claude sign-in on the device row")
    }

    private func showClaudeIfHidden(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["providerToggle-claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" {
            // SwiftUI는 Form 행 전체를 스위치로 노출한다, 가운데 라벨이 아니라 컨트롤 쪽을 누른다
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        app.buttons["settingsDone"].tap()
    }
}
