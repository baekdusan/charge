import XCTest
@testable import Charge

final class QuotaProtectionTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func date(_ value: String) -> Date {
        guard let date = iso.date(from: value) else {
            XCTFail("Invalid test date: \(value)")
            return .distantPast
        }
        return date
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func provider(
        session: RateWindow?,
        weekly: RateWindow?,
        extras: [ExtraWindow]? = nil,
        account: String = "acct-a"
    ) -> Provider {
        Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: session,
            weekly: weekly,
            extras: extras,
            status: nil,
            account: account
        )
    }

    private func block(
        account: String,
        observedAccounts: [String]? = nil,
        first: String = "2026-08-15T15:06:00Z",
        reset: String = "2026-08-16T15:00:00Z",
        cleared: String? = nil
    ) -> QuotaBlock {
        QuotaBlock(
            providerId: "claude",
            account: account,
            windowKind: "weekly",
            resetAt: reset,
            observedAccounts: observedAccounts,
            firstSeenAt: first,
            lastSeenAt: first,
            clearedAt: cleared
        )
    }

    func testWeeklyHundredOverridesZeroPercentSession() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(
                percent: 100,
                resetsAt: "2026-08-16T15:00:00Z",
                windowMinutes: 10_080
            ),
            extras: [ExtraWindow(
                name: "Fable",
                window: RateWindow(percent: 100, resetsAt: "2026-08-16T15:00:00Z")
            )]
        )

        let limit = value.providerWideLimit(at: now)
        XCTAssertEqual(limit?.window.windowMinutes, 10_080)
        XCTAssertTrue(limit?.isProviderWide == true)
        XCTAssertEqual(value.activeLimit(at: now)?.window.windowMinutes, 10_080)
    }

    func testScopedLimitDoesNotBlockWholeProvider() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(percent: 50, resetsAt: "2026-08-16T15:00:00Z", windowMinutes: 10_080),
            extras: [ExtraWindow(
                name: "Fable",
                window: RateWindow(percent: 100, resetsAt: "2026-08-16T15:00:00Z")
            )]
        )

        XCTAssertNil(value.providerWideLimit(at: now))
        XCTAssertFalse(value.activeLimit(at: now)?.isProviderWide ?? true)
    }

    func testProtectionRequiresWholeDayAndHonorsEarlyClear() {
        let day = date("2026-08-16T03:00:00Z")
        let calendar = calendar()

        XCTAssertTrue(block(account: "acct-a").protects(day, calendar: calendar))
        XCTAssertTrue(block(
            account: "acct-a",
            first: "2026-08-15T15:30:00Z"
        ).protects(day, calendar: calendar))
        XCTAssertFalse(block(
            account: "acct-a",
            first: "2026-08-15T15:31:00Z"
        ).protects(day, calendar: calendar))
        XCTAssertFalse(block(
            account: "acct-a",
            first: "2026-08-16T03:00:00Z"
        ).protects(day, calendar: calendar))
        XCTAssertFalse(block(
            account: "acct-a",
            cleared: "2026-08-16T03:00:00Z"
        ).protects(day, calendar: calendar))
    }

    func testEveryCurrentAccountMustBeBlocked() {
        let now = date("2026-08-16T03:00:00Z")
        let calendar = calendar()
        let accounts: Set<String> = ["acct-a", "acct-b"]

        let partial = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: accounts,
            blocks: [block(account: "acct-a")],
            now: now,
            historyDays: 1,
            calendar: calendar
        )
        XCTAssertTrue(partial.isEmpty)

        let complete = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: accounts,
            blocks: [
                block(account: "acct-a", observedAccounts: ["acct-a", "acct-b"]),
                block(account: "acct-b", observedAccounts: ["acct-a", "acct-b"])
            ],
            now: now,
            historyDays: 1,
            calendar: calendar
        )
        XCTAssertEqual(complete, ["2026-08-16"])
    }

    func testRemovedAvailableAccountStillPreventsRetroactiveProtection() {
        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a"],
            blocks: [block(account: "acct-a", observedAccounts: ["acct-a", "acct-b"])],
            now: date("2026-08-16T03:00:00Z"),
            historyDays: 1,
            calendar: calendar()
        )

        XCTAssertTrue(protected.isEmpty)
    }

    /// 두 계정이 모두 하루 종일 막혔던 날은, 나중에 그중 하나를 연결 해제해도 보호가 유지돼야 한다.
    /// 서버는 기기와 무관하게 증거를 남기는데 앱이 현재 계정으로 먼저 걸러 버리면
    /// 만족할 수 없는 조건이 되어 과거 방패가 소급 취소된다.
    func testUnlinkingOneBlockedAccountKeepsPastProtection() {
        let blocks = [
            block(account: "acct-a", observedAccounts: ["acct-a", "acct-b"]),
            block(account: "acct-b", observedAccounts: ["acct-a", "acct-b"])
        ]

        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a"],
            blocks: blocks,
            now: date("2026-08-16T03:00:00Z"),
            historyDays: 1,
            calendar: calendar()
        )

        XCTAssertEqual(protected, ["2026-08-16"])
    }

    /// 계정을 하나 쓰던 시절에 종일 막혔던 날은, 나중에 두 번째 계정을 연결해도 그대로
    /// 보호돼야 한다. 그날 존재하지도 않던 계정에 차단 증거를 요구하면 과거 스트릭이
    /// 소급해서 끊긴다. 지난 창의 구간은 리셋이 지나 다시 갱신되지도 않는다.
    func testLinkingNewAccountKeepsPastProtection() {
        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a", "acct-b"],
            blocks: [block(account: "acct-a", observedAccounts: ["acct-a"])],
            now: date("2026-08-16T03:00:00Z"),
            historyDays: 1,
            calendar: calendar()
        )

        XCTAssertEqual(protected, ["2026-08-16"])
    }

    /// 하루 종일 막힌 계정 A와, 정오부터만 막힌 계정 B가 있던 날. B를 나중에 연결 해제해도
    /// 그날은 실제로 B로 일할 수 있었으므로 보호하면 안 된다. 완결성 검사에 쓰는 계정 집합을
    /// 하루를 다 덮은 구간에서만 모으면 B의 증거가 빠져 거짓 보호가 된다.
    func testPartiallyBlockedRemovedAccountPreventsProtection() {
        let calendar = calendar()
        let wholeDayA = block(
            account: "acct-a",
            observedAccounts: ["acct-a", "acct-b"],
            first: "2026-08-15T15:06:00Z",
            reset: "2026-08-20T15:00:00Z"
        )
        // B는 08-16(KST) 정오부터 막혔다. 그날 오전에는 쓸 수 있었다.
        let halfDayB = block(
            account: "acct-b",
            observedAccounts: ["acct-a", "acct-b"],
            first: "2026-08-16T03:00:00Z",
            reset: "2026-08-20T15:00:00Z"
        )

        // 08-16(KST) 낮을 기준으로 그날 하루만 본다.
        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a"],
            blocks: [wholeDayA, halfDayB],
            now: date("2026-08-16T06:00:00Z"),
            historyDays: 1,
            calendar: calendar
        )

        XCTAssertTrue(protected.isEmpty, "반나절만 막힌 계정이 있던 날을 보호했다")
    }

    /// 보호일 키는 스트릭 격자의 period 키(그레고리력)와 만나야 한다. 주입된 달력을 그대로
    /// 포매터에 넘기면 불교력 지역에서 "2569-08-16"이 나와 어떤 키와도 만나지 못하고
    /// 기능이 조용히 죽는다.
    func testProtectionKeysUseGregorianCalendarInNonGregorianLocales() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Seoul")!

        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a"],
            blocks: [block(account: "acct-a", observedAccounts: ["acct-a"])],
            now: date("2026-08-16T03:00:00Z"),
            historyDays: 1,
            calendar: buddhist
        )

        XCTAssertEqual(protected, ["2026-08-16"])
    }

    /// 해제된 구간과 재차단 구간이 같은 창에 함께 있으면, 각 구간이 실제로 덮은 날만 보호한다.
    /// 창당 한 행으로 뭉개면 둘 중 하나가 반드시 틀린다.
    func testReblockIntervalProtectsItsOwnDayOnly() {
        let calendar = calendar()
        let cleared = block(
            account: "acct-a",
            observedAccounts: ["acct-a"],
            first: "2026-08-14T15:06:00Z",
            reset: "2026-08-20T15:00:00Z",
            cleared: "2026-08-15T20:00:00Z"
        )
        let reblocked = block(
            account: "acct-a",
            observedAccounts: ["acct-a"],
            first: "2026-08-16T15:10:00Z",
            reset: "2026-08-20T15:00:00Z"
        )

        // 08-15(KST)는 해제 전이라 첫 구간이 하루를 다 덮는다.
        XCTAssertTrue(cleared.protects(date("2026-08-15T03:00:00Z"), calendar: calendar))
        // 08-16(KST)은 아침에 풀려 실제로 쓸 수 있었던 날이다. 어느 구간도 덮지 않아야 한다.
        XCTAssertFalse(cleared.protects(date("2026-08-16T03:00:00Z"), calendar: calendar))
        XCTAssertFalse(reblocked.protects(date("2026-08-16T03:00:00Z"), calendar: calendar))
        // 08-17(KST)은 재차단 구간이 자정 직후부터 리셋까지 덮는다.
        XCTAssertTrue(reblocked.protects(date("2026-08-17T03:00:00Z"), calendar: calendar))

        let protected = StreakProtection.protectedPeriods(
            providerId: "claude",
            accounts: ["acct-a"],
            blocks: [cleared, reblocked],
            now: date("2026-08-17T03:00:00Z"),
            historyDays: 3,
            calendar: calendar
        )
        // 해제 시각을 지우면 08-16까지 보호되고(거짓 양성), 창당 한 행으로 뭉개면
        // 08-17을 놓친다(거짓 음성). 구간을 따로 저장해야 둘 다 맞는다.
        XCTAssertEqual(protected, ["2026-08-15", "2026-08-17"])
    }

    // MARK: 대표 창 (잠금화면 위젯이 숫자 하나만 그리는 패밀리)

    /// 세션 창이 없고 주간만 있는 상태는 캐시 폴백에서 흔하다. 여기서 대표 창을 못 고르면
    /// 앱 카드와 홈 위젯은 "Weekly 62%"를 그리는데 잠금화면만 "No data"가 된다.
    func testWeeklyBecomesPrimaryWhenSessionWindowIsMissing() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: nil,
            weekly: RateWindow(percent: 62, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080)
        )

        let primary = value.primaryDisplayWindow(at: now)
        XCTAssertEqual(primary?.id, "weekly")
        XCTAssertEqual(primary?.window.percent, 62)
    }

    /// 계정 전체가 막혀 있으면 세션 0%가 아니라 막고 있는 창이 대표 숫자여야 한다.
    func testBlockingWindowOutranksSessionAsPrimary() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(percent: 100, resetsAt: "2026-08-16T15:00:00Z", windowMinutes: 10_080)
        )

        let primary = value.primaryDisplayWindow(at: now)
        XCTAssertEqual(primary?.id, "blocking")
        XCTAssertEqual(primary?.window.percent, 100)
    }

    /// 그릴 창이 하나도 없으면 대표 창도 없다. 이때만 "No data"가 맞다.
    func testNoPrimaryWindowWhenNothingIsDrawable() {
        let now = date("2026-08-15T16:00:00Z")
        XCTAssertNil(provider(session: nil, weekly: nil).primaryDisplayWindow(at: now))
    }
}
