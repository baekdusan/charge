import XCTest
@testable import Charge

/// 화면 확인용 데모 런치 인자. 인자가 없으면 기본 데모 데이터(심사, 스크린샷)가 그대로여야 한다.
final class DemoFixtureTests: XCTestCase {
    /// 스트릭 격자와 보호일 판정은 "오늘"을 기준으로 하므로 실제 현재 시각을 쓴다
    private let now = Date()

    private func claude(_ payload: UsagePayload) -> Provider? {
        payload.providers?.first { $0.id == "claude" }
    }

    private func period(daysAgo: Int) -> String {
        ChargeDate.day.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!)
    }

    func testDefaultDemoDataIsUnchangedWithoutFixtureArguments() throws {
        let payload = DemoData.make(now: now, arguments: [])
        let claude = try XCTUnwrap(claude(payload))
        XCTAssertEqual(claude.session?.percent, 34)
        XCTAssertNotNil(claude.session?.resetsAt)
        XCTAssertEqual(claude.weekly?.percent, 62)
        XCTAssertFalse(claude.freshness(at: now).isStale)
        XCTAssertNil(payload.quotaBlocks)
        XCTAssertNotNil(payload.live)
        XCTAssertEqual(payload.liveBlocks?.count, 1)
        for back in 0..<2 {
            let day = payload.daily.first { $0.period == period(daysAgo: back) }
            XCTAssertGreaterThan(day?.cost(for: "claude") ?? 0, 0)
        }
        XCTAssertEqual(payload.providers?.map(\.id), ["claude", "codex", "gemini"])
        // 다른 인자(복구 픽스처)도 이 두 픽스처 상태를 만들지 않는다
        let recovery = DemoData.make(now: now, arguments: ["-charge-demo-collection-failures", "5", "-charge-demo-second-device"])
        XCTAssertNil(recovery.quotaBlocks)
        XCTAssertEqual(self.claude(recovery)?.weekly?.percent, 62)
        XCTAssertFalse(self.claude(recovery)?.freshness(at: now).isStale ?? true)
    }

    func testQuotaProtectionFixtureProtectsYesterdayAndToday() throws {
        let payload = DemoData.make(now: now, arguments: ["-charge-demo-quota-protection"])
        let claude = try XCTUnwrap(claude(payload))
        XCTAssertEqual(claude.weekly?.percent, 100)
        XCTAssertEqual(claude.providerWideLimit(at: now)?.window.windowMinutes, 10_080)

        // ContentView.protectedPeriods와 같은 입력(현재 계정 집합, 차단 구간, 현재 달력)
        let accounts = Set((payload.providers ?? []).filter { $0.id == "claude" }.map { $0.account ?? "" })
        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: accounts,
            blocks: payload.quotaBlocks ?? []
        )
        XCTAssertTrue(protected.contains(period(daysAgo: 0)), "오늘")
        XCTAssertTrue(protected.contains(period(daysAgo: 1)), "어제")
        XCTAssertFalse(protected.contains(period(daysAgo: 2)), "그저께는 자정 뒤에 막혔으니 보호일이 아니다")

        // 보호일 칸은 그 프로바이더 사용량이 0인 날에만 그려진다. 다른 프로바이더는 계속 썼다
        for back in 0..<2 {
            let day = try XCTUnwrap(payload.daily.first { $0.period == period(daysAgo: back) })
            XCTAssertEqual(day.cost(for: "claude"), 0, "\(back)일 전")
            XCTAssertGreaterThan(day.totalCost, 0)
            XCTAssertEqual(day.totalCost, day.cost(for: nil))
        }
        let beforeBlock = payload.daily.first { $0.period == period(daysAgo: 2) }
        XCTAssertGreaterThan(beforeBlock?.cost(for: "claude") ?? 0, 0)
        XCTAssertNil(payload.live, "한도에 막힌 동안에는 5시간 블록도 없다")
        XCTAssertEqual(payload.liveBlocks?.count ?? 0, 0)
    }

    func testStaleClaudeFixtureDrawsUnknownSessionGauge() throws {
        let payload = DemoData.make(now: now, arguments: ["-charge-demo-stale-claude"])
        let claude = try XCTUnwrap(claude(payload))
        guard case .stale(let collected) = claude.freshness(at: now) else {
            return XCTFail("사흘 전 스냅샷은 낡은 것으로 보여야 한다")
        }
        XCTAssertEqual(now.timeIntervalSince(collected), 3 * 86400, accuracy: 1)
        let session = try XCTUnwrap(claude.session)
        XCTAssertNil(session.resetsAt)
        XCTAssertEqual(claude.displayState(of: session, at: now)?.isUnknown, true)
        let weekly = try XCTUnwrap(claude.displayState(of: try XCTUnwrap(claude.weekly), at: now))
        XCTAssertFalse(weekly.isUnknown)
        // 기본 데모의 같은 주간 창(62%)은 소진 예측을 그리지만, 사흘 묵은 스냅샷에서는 그리지 않는다
        XCTAssertNil(weekly.paceWarning)
        let defaultClaude = try XCTUnwrap(self.claude(DemoData.make(now: now, arguments: [])))
        XCTAssertNotNil(defaultClaude.displayState(of: try XCTUnwrap(defaultClaude.weekly), at: now)?.paceWarning)

        // 다른 프로바이더는 그대로 신선하고, 사흘은 오래된 카드 경계 안이라 카드도 그대로 보인다
        XCTAssertFalse(payload.providers?.first { $0.id == "codex" }?.freshness(at: now).isStale ?? true)
        XCTAssertEqual((payload.providers ?? []).hidingOutdatedCards(at: now).count, payload.providers?.count)
        XCTAssertNil(payload.quotaBlocks)
    }
}
