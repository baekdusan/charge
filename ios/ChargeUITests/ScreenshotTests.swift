import XCTest

/// App Store 스크린샷 자동 촬영 — 데모 모드로 앱을 띄워 주요 화면을 PNG로 저장한다.
/// 저장 경로: SCREENSHOT_DIR 환경변수 (환경변수 `TEST_RUNNER_SCREENSHOT_DIR=<경로> xcodebuild test ...`
/// 형태로 xcodebuild 프로세스 환경에 넣어야 러너까지 전달된다. 미지정 시 /tmp/charge-shots)
final class ScreenshotTests: XCTestCase {
    private var shotDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/charge-shots",
            isDirectory: true)
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
    }

    /// 짧은 안정화 대기 후 캡처 — 저장 실패는 테스트 실패로 드러나야 한다
    /// (조용히 넘어가면 스크린샷 0장인 채 초록불이 된다)
    private func capture(_ name: String, settle: TimeInterval = 1) throws {
        Thread.sleep(forTimeInterval: settle)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("\(name).png"))
    }

    func testCaptureScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo"]
        app.launch()

        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "메인 화면이 뜨지 않았다")
        try capture("01-main")

        app.swipeUp()
        try capture("02-streak")

        app.swipeUp()
        try capture("03-chart")

        settings.tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 10), "설정 시트가 뜨지 않았다")
        try capture("04-settings")

        // 온보딩(로그인 화면): 데모 오버라이드를 끄고 재실행 — 시뮬레이터에는 세션이 없다
        app.terminate()
        app.launchArguments = ["-charge-demo-off"]
        app.launch()
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 20), "온보딩이 뜨지 않았다")
        try capture("05-onboarding")
    }
}
