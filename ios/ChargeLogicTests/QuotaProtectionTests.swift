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

    // MARK: 창 목록 (세션 → 주간 → extras 순서와 이름, 범위)

    /// 순서가 strictest()의 동률과 대표 창을 정하고, id는 저장된 리셋 알림 id와 위젯 줄 id에 그대로 쓰인다.
    func testWindowsListOrderIdsTitlesAndScope() {
        let value = provider(
            session: RateWindow(percent: 10, resetsAt: "2026-08-15T18:00:00Z", windowMinutes: 300),
            weekly: RateWindow(percent: 20, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080, label: "All models"),
            extras: [ExtraWindow(
                name: "Fable",
                window: RateWindow(percent: 30, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080, label: "Fable weekly")
            )]
        )

        let windows = value.windows
        XCTAssertEqual(windows.map(\.id), ["session", "weekly", "extra-Fable"])
        XCTAssertEqual(windows.map(\.title), [String(localized: "Session"), "All models", "Fable weekly"])
        XCTAssertEqual(windows.map(\.isProviderWide), [true, true, false])
        XCTAssertEqual(windows.map(\.window.percent), [10, 20, 30])
        XCTAssertEqual(windows.map(\.slot), [.session, .weekly, .extra(name: "Fable")])
    }

    /// label이 없는 extra는 이름으로, 없는 창은 항목 자체가 없다
    func testWindowsListFallsBackToNameAndSkipsMissingWindows() {
        let value = provider(
            session: nil,
            weekly: RateWindow(percent: 20, resetsAt: nil),
            extras: [ExtraWindow(name: "Opus", window: RateWindow(percent: 5, resetsAt: nil))]
        )
        XCTAssertEqual(value.windows.map(\.id), ["weekly", "extra-Opus"])
        XCTAssertEqual(value.windows.map(\.title), [String(localized: "Weekly"), "Opus"])
    }

    /// Ultra 플랜은 5시간 세션 창이 없고(session: null), 주간과 모델 범위 Fable 주간만 온다.
    /// Fable 100%는 계정 전체 차단이 아니고, 대표 창은 주간이다.
    func testUltraShapeWithoutSessionUsesWeeklyAndScopesFable() {
        let now = date("2026-11-11T06:00:00Z")
        let value = provider(
            session: nil,
            weekly: RateWindow(percent: 65, resetsAt: "2026-11-15T15:00:00.621900+00:00", windowMinutes: 10_080),
            extras: [ExtraWindow(
                name: "Fable",
                window: RateWindow(
                    percent: 100,
                    resetsAt: "2026-11-15T15:00:00.621900+00:00",
                    windowMinutes: 10_080,
                    label: "Fable weekly"
                )
            )]
        )

        XCTAssertEqual(value.primaryDisplayWindow(at: now)?.id, "weekly")
        XCTAssertEqual(value.primaryDisplayWindow(at: now)?.window.percent, 65)
        XCTAssertNil(value.providerWideLimit(at: now))
        let scoped = value.scopedLimit(at: now)
        XCTAssertEqual(scoped?.title, "Fable weekly")
        XCTAssertEqual(scoped?.isProviderWide, false)
        XCTAssertEqual(value.activeLimit(at: now)?.title, "Fable weekly")
        XCTAssertEqual(
            value.drawableWindows(at: now, stale: false).map(\.window.id),
            ["weekly", "extra-Fable"]
        )
    }

    /// 대표 창 규칙("값을 아는 첫 계정 전체 창, 없으면 첫 창")이 예전 세션/주간 분기와 모든 조합에서 같은 답을 내는지.
    func testPrimaryWindowMatchesSessionWeeklyBranchesForEveryCombination() {
        let now = date("2026-08-15T16:00:00Z")
        enum Kind: CaseIterable { case missing, undrawable, unknown, known }
        func window(_ kind: Kind) -> RateWindow? {
            switch kind {
            case .missing: return nil
            // 리셋이 지났는데 창 길이를 몰라 다음 창을 추정할 수 없다
            case .undrawable: return RateWindow(percent: 40, resetsAt: "2026-08-15T10:00:00Z")
            // 묵은 스냅샷 + 리셋 시각 없음
            case .unknown: return RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300)
            case .known: return RateWindow(percent: 30, resetsAt: "2026-08-15T18:00:00Z", windowMinutes: 300)
            }
        }
        for s in Kind.allCases {
            for w in Kind.allCases {
                var value = provider(session: window(s), weekly: window(w))
                value.collectedAt = "2026-08-15T15:20:00Z"  // 40분 묵음
                let sessionDrawable = s == .unknown || s == .known
                let weeklyDrawable = w == .unknown || w == .known
                let expected: String?
                if sessionDrawable && !(s == .unknown && w == .known) {
                    expected = "session"
                } else if weeklyDrawable {
                    expected = "weekly"
                } else {
                    expected = nil
                }
                XCTAssertEqual(value.primaryDisplayWindow(at: now)?.id, expected, "session \(s), weekly \(w)")
            }
        }
    }

    // MARK: 위젯 칸 (그릴 수 있는 창을 세션 → 주간 → extras 순서로 최대 두 칸)

    /// Ultra(세션 없음)는 빈 "Session -" 칸 대신 주간 + Fable 주간을 그린다
    func testWidgetWindowsForUltraAreWeeklyThenFable() {
        let now = date("2026-11-11T06:00:00Z")
        let value = provider(
            session: nil,
            weekly: RateWindow(percent: 65, resetsAt: "2026-11-15T15:00:00.621900+00:00", windowMinutes: 10_080),
            extras: [ExtraWindow(
                name: "Fable",
                window: RateWindow(percent: 40, resetsAt: "2026-11-15T15:00:00Z", windowMinutes: 10_080, label: "Fable weekly")
            )]
        )
        XCTAssertEqual(value.widgetWindows(at: now).map(\.id), ["weekly", "extra-Fable"])
        XCTAssertEqual(value.widgetWindows(at: now).map(\.title), [String(localized: "Weekly"), "Fable weekly"])
        XCTAssertEqual(value.widgetWindows(at: now, limit: 1).map(\.id), ["weekly"])
    }

    /// Pro/Max는 extras가 있어도 세션 + 주간 그대로다
    func testWidgetWindowsForProAreSessionThenWeekly() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: RateWindow(percent: 10, resetsAt: "2026-08-15T18:00:00Z", windowMinutes: 300),
            weekly: RateWindow(percent: 20, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080),
            extras: [ExtraWindow(name: "Fable", window: RateWindow(percent: 30, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080))]
        )
        XCTAssertEqual(value.widgetWindows(at: now).map(\.id), ["session", "weekly"])
        XCTAssertEqual(value.widgetWindows(at: now).map(\.title), [String(localized: "Session"), String(localized: "Weekly")])
    }

    /// 리셋이 지났는데 창 길이를 몰라 추정할 수 없는 세션은 칸을 차지하지 않고, 다음 창이 올라온다.
    /// 값 미상(묵은 스냅샷 + 리셋 시각 없음)인 창은 그릴 수 있으니 칸을 그대로 차지한다.
    func testWidgetWindowsSkipUndrawableButKeepUnknown() {
        let now = date("2026-08-15T16:00:00Z")
        let fable = ExtraWindow(name: "Fable", window: RateWindow(percent: 30, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080))
        var undrawable = provider(
            session: RateWindow(percent: 40, resetsAt: "2026-08-15T10:00:00Z"),
            weekly: RateWindow(percent: 20, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080),
            extras: [fable]
        )
        undrawable.collectedAt = "2026-08-15T15:20:00Z"  // 40분 묵음
        XCTAssertEqual(undrawable.widgetWindows(at: now).map(\.id), ["weekly", "extra-Fable"])

        var unknown = provider(
            session: RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300),
            weekly: RateWindow(percent: 20, resetsAt: "2026-08-20T15:00:00Z", windowMinutes: 10_080),
            extras: [fable]
        )
        unknown.collectedAt = "2026-08-15T15:20:00Z"
        XCTAssertEqual(unknown.widgetWindows(at: now).map(\.id), ["session", "weekly"])
        XCTAssertEqual(unknown.displayState(of: unknown.widgetWindows(at: now)[0].window, at: now)?.isUnknown, true)
    }

    /// extras만 그릴 수 있는 프로바이더도 위젯에서 빠지지 않는다(앱 카드와 같다)
    func testWidgetWindowsForExtrasOnlyProvider() {
        let now = date("2026-08-15T16:00:00Z")
        let value = provider(
            session: nil,
            weekly: RateWindow(percent: 20, resetsAt: "2026-08-15T10:00:00Z"),  // 추정 불가
            extras: [ExtraWindow(name: "Opus", window: RateWindow(percent: 5, resetsAt: nil))]
        )
        XCTAssertEqual(value.widgetWindows(at: now).map(\.id), ["extra-Opus"])
        XCTAssertEqual(value.widgetWindows(at: now).map(\.title), ["Opus"])
        XCTAssertTrue(provider(session: nil, weekly: nil).widgetWindows(at: now).isEmpty)
        // 홈 위젯이 그리는 프로바이더는 대표 창 화면(링, 막대, 인라인)에서도 사라지지 않는다
        XCTAssertEqual(value.primaryDisplayWindow(at: now)?.id, "extra-Opus")
        XCTAssertNil(provider(session: nil, weekly: nil).primaryDisplayWindow(at: now))
        // 계정 전체 창이 하나라도 그려지면 extras는 대표가 되지 않는다(Fable 100%여도 주간이 대표)
        let ultra = provider(
            session: nil,
            weekly: RateWindow(percent: 40, resetsAt: "2026-08-20T10:00:00Z"),
            extras: [ExtraWindow(name: "Fable", window: RateWindow(percent: 90, resetsAt: "2026-08-20T10:00:00Z"))]
        )
        XCTAssertEqual(ultra.primaryDisplayWindow(at: now)?.id, "weekly")
    }

    // MARK: ISO-8601 시각

    func testInstantParsesFractionalAndPlainTimestamps() {
        let plain = ChargeDate.instant("2026-11-15T15:00:00Z")
        XCTAssertEqual(plain, date("2026-11-15T15:00:00Z"))
        let fractional = ChargeDate.instant("2026-11-15T15:00:00.621900+00:00")
        XCTAssertNotNil(fractional)
        XCTAssertEqual(
            fractional?.timeIntervalSince(date("2026-11-15T15:00:00Z")) ?? -1,
            0.6219,
            accuracy: 0.001
        )
        XCTAssertEqual(ChargeDate.instant("2026-11-15T15:00:00+00:00"), date("2026-11-15T15:00:00Z"))
        XCTAssertNil(ChargeDate.instant(nil))
        XCTAssertNil(ChargeDate.instant(""))
        XCTAssertNil(ChargeDate.instant("x"))
    }

    /// 추정 창의 resetsAt은 소수점 형식으로 쓴다(위젯 지문이 이 문자열을 비교한다), 다시 읽어도 같은 시각이다.
    func testInferredResetIsWrittenFractionalAndRoundTrips() {
        XCTAssertEqual(ChargeDate.isoString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        let now = date("2026-08-15T16:00:00Z")
        let passed = RateWindow(percent: 80, resetsAt: "2026-08-15T15:00:00Z", windowMinutes: 300)
        let inferred = passed.displayState(at: now)?.window
        XCTAssertEqual(inferred?.resetsAt, "2026-08-15T20:00:00.000Z")
        XCTAssertEqual(inferred?.resetDate, date("2026-08-15T20:00:00Z"))
    }
}
