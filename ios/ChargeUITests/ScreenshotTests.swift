import XCTest

/// App Store 스크린샷 자동 촬영 — 데모 모드로 앱을 띄워 주요 화면을 PNG로 저장한다.
/// 저장 경로: SCREENSHOT_DIR 환경변수 (환경변수 `TEST_RUNNER_SCREENSHOT_DIR=<경로> xcodebuild test ...`
/// 형태로 xcodebuild 프로세스 환경에 넣어야 러너까지 전달된다. 미지정 시 /tmp/charge-shots)
/// 홈 화면 당겨서 새로고침 회귀 테스트 — 데모 지연(-charge-demo-latency)으로 느린 네트워크를
/// 흉내낸다. XCUITest는 제스처 후 앱이 안정될 때까지(=새로고침 인디케이터 애니메이션이 끝날
/// 때까지) 블로킹되므로, 제스처 경과 시간이 지연 이상이면 "새로고침이 트리거됐고 인디케이터가
/// 로드 완료까지 유지됐다"는 뜻이다. (인디케이터가 즉시 접히면 경과 시간이 지연보다 짧아진다)
final class RefreshTests: XCTestCase {
    func testPullToRefreshKeepsSpinnerUntilLoaded() throws {
        let latency = 2.5
        let app = XCUIApplication()
        app.launchArguments = ["-charge-demo", "-charge-demo-latency", "\(latency)"]
        app.launch()

        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 20), "메인 화면이 뜨지 않았다")
        // 초기 로드(역시 지연 적용)가 끝나 화면이 안정될 때까지 대기
        Thread.sleep(forTimeInterval: latency + 2)

        // 당겨서 새로고침: 위에서 아래로 드래그 후 잠시 유지하고 놓는다 (일반적인 사용 패턴)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists, "스크롤뷰를 찾지 못했다")
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.1))
        let began = Date()
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertGreaterThan(
            elapsed, latency,
            "당겨서 새로고침이 트리거되지 않았거나 인디케이터가 로드 완료 전에 접혔다"
        )
    }
}

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
