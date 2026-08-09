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

/// 잠금화면 위젯 실촬영 준비 (마케팅용, 임시) — SpringBoard를 XCUITest로 조작해
/// 잠금화면 사용자화 → Charge 위젯 추가까지 자동화한다. 단계별 스크린샷·UI 덤프를
/// SCREENSHOT_DIR에 남겨 다음 단계를 탐색한다.
final class LockWidgetTests: XCTestCase {
    private var shotDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/charge-shots",
            isDirectory: true)
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
    }

    private func shoot(_ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("\(name).png"))
    }

    private func dump(_ name: String, _ text: String) throws {
        try text.write(to: shotDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 1단계: 온보딩의 "데모 둘러보기"를 눌러 demoMode를 App Group에 영구 저장 —
    /// 잠금화면 위젯 타임라인이 데모 데이터를 그리게 된다
    func testEnableDemo() throws {
        let app = XCUIApplication()
        app.launch()
        let demoBtn = app.buttons["데모 둘러보기"]
        if demoBtn.waitForExistence(timeout: 10) {
            demoBtn.tap()
        }
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 15), "데모 진입 실패")
    }

    /// 2단계(탐색): 기기 잠금 → 잠금화면 길게 눌러 사용자화 진입 시도, 상태 덤프
    func testEnterLockCustomize() throws {
        let device = XCUIDevice.shared
        XCTAssertTrue(device.responds(to: NSSelectorFromString("pressLockButton")), "pressLockButton 미지원")
        device.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1)
        device.press(.home) // 화면 깨우기 → 잠금화면
        Thread.sleep(forTimeInterval: 1.5)
        try shoot("L1-locked")

        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
        Thread.sleep(forTimeInterval: 2)
        try shoot("L2-longpress")
        try dump("L2-springboard.txt", sb.debugDescription)
    }

    /// 3단계: 사용자화 → 잠금 화면 → 위젯 추가 → Charge 위젯 3종 추가 → 완료.
    /// 요소를 못 찾으면 그 지점의 스크린샷·덤프를 남기고 실패한다.
    func testAddWidgets() throws {
        let device = XCUIDevice.shared
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let customize = sb.buttons["posterboard-customize-button"]
        if !customize.waitForExistence(timeout: 3) {
            // 스위처가 아직 안 떠 있으면 잠금 → 깨우기 → 길게 누르기로 진입
            device.perform(NSSelectorFromString("pressLockButton"))
            Thread.sleep(forTimeInterval: 1)
            device.press(.home)
            Thread.sleep(forTimeInterval: 1.5)
            sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
            Thread.sleep(forTimeInterval: 2)
        }
        // 사용자화를 누르면 곧장 잠금화면 편집 모드로 들어간다 (선택 화면 없음)
        let addWidgets = sb.buttons["grouped-widgets-reticle-view"]
        if !addWidgets.exists {
            try tapStep(sb, customize, "W1-customize")
        }
        try tapStep(sb, addWidgets, "W3-widgetarea")

        // 갤러리에서 Charge 앱 선택 — 목록이 길어 스와이프로 찾는다
        let chargeRow = sb.cells.matching(NSPredicate(format: "label == 'Charge'")).firstMatch
        var tries = 0
        while !(chargeRow.exists && chargeRow.isHittable), tries < 12 {
            sb.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
            tries += 1
        }
        try tapStep(sb, chargeRow, "W4-gallery")

        try shoot("W5-charge-widgets")
        try dump("W5-charge-widgets.txt", sb.debugDescription)
    }

    /// 4단계: 위젯 3종 추가(링·숫자·요약 = 스트립 4칸) → 닫기 → 완료 → 잠금화면 복귀
    func testPickWidgetsAndFinish() throws {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for (i, label) in ["Charge, 한도 링", "Charge, 한도 숫자", "Charge, 사용량 요약"].enumerated() {
            let btn = sb.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard btn.waitForExistence(timeout: 4) else { break } // 이미 추가돼 상세가 닫힌 상태면 건너뜀
            try tapStep(sb, btn, "W6-pick-\(i)")
        }
        // X는 Charge 상세만 닫는다 — 시트 자체는 손잡이를 아래로 드래그해 내린다
        let closeBtn = sb.buttons["닫기"].firstMatch
        if closeBtn.waitForExistence(timeout: 3) {
            try tapStep(sb, closeBtn, "W7-close")
        }
        let handle = sb.buttons["시트 손잡이"].firstMatch
        if handle.waitForExistence(timeout: 3) {
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.05)))
            Thread.sleep(forTimeInterval: 1.5)
            try shoot("W7b-sheet-dismissed")
        }
        try tapStep(sb, sb.buttons["editing-done"].firstMatch, "W8-done")
        Thread.sleep(forTimeInterval: 2)
        try shoot("W9-after-done")
        try dump("W9-after-done.txt", sb.debugDescription)
    }

    /// 5단계: 스위처에서 포스터를 탭해 잠금화면으로 복귀 → 알림 지우기 → 최종 캡처
    func testCaptureLockScreen() throws {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // 스위처가 떠 있으면 포스터를 탭해 잠금화면으로 나간다
        if sb.buttons["posterboard-customize-button"].waitForExistence(timeout: 3) {
            sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 2.5)
        }

        // 어떤 상태에서 시작하든 잠금 → 깨우기로 잠금화면을 띄운다
        let device = XCUIDevice.shared
        device.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1)
        device.press(.home)
        Thread.sleep(forTimeInterval: 2)

        // 잠금화면 알림 제거 — 한 번 잠금 해제하면 확인된 것으로 처리돼 잠금화면에서 사라진다
        if sb.buttons.matching(identifier: "ListCell").firstMatch.waitForExistence(timeout: 3) {
            device.press(.home) // 잠금 해제 (시뮬레이터는 암호 없음)
            Thread.sleep(forTimeInterval: 2)
            device.perform(NSSelectorFromString("pressLockButton"))
            Thread.sleep(forTimeInterval: 1)
            device.press(.home) // 깨우기 → 잠금화면
            Thread.sleep(forTimeInterval: 2)
        }

        Thread.sleep(forTimeInterval: 1.5)
        try shoot("LOCK-final")
        try dump("LOCK-final.txt", sb.debugDescription)
    }

    private struct StepError: Error { let name: String }

    /// 요소가 나타나면 탭하고 스크린샷을 남긴다. 못 찾으면 실패 지점 덤프 후 throw.
    private func tapStep(_ sb: XCUIApplication, _ el: XCUIElement, _ name: String) throws {
        guard el.waitForExistence(timeout: 6) else {
            try? shoot("\(name)-FAIL")
            try? dump("\(name)-FAIL.txt", sb.debugDescription)
            throw StepError(name: name)
        }
        el.tap()
        Thread.sleep(forTimeInterval: 1.5)
        try shoot(name)
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
