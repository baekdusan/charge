import XCTest
@testable import Charge

/// 묵은 데이터를 "지금 값"처럼 그리지 않는 규칙.
/// A1: 묵은 스냅샷 + 리셋 시각 없는 창은 0%가 아니라 값 미상이다.
/// A2, D10: 가장 긴 창(7일 이상)보다 오래된 카드는 같은 프로바이더에 확실히 더 신선한 카드가 있으면 뺀다.
/// 이 정리는 표시 단계 전용이다(병합 결과, 스트릭 보호 계정 목록에는 남는다).
final class StaleDataDisplayTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date(timeIntervalSince1970: 1_789_344_000)

    private func stamp(_ date: Date) -> String { iso.string(from: date) }

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func provider(
        id: String = "claude",
        account: String = "acct-a",
        session: RateWindow? = nil,
        weekly: RateWindow?,
        collectedAt: Date?
    ) -> Provider {
        Provider(
            id: id,
            name: id.capitalized,
            plan: nil,
            session: session,
            weekly: weekly,
            extras: nil,
            status: nil,
            account: account,
            collectedAt: collectedAt.map(stamp)
        )
    }

    // MARK: A1 값 미상 게이지

    func testStaleWindowWithoutResetIsUnknown() {
        let noReset = RateWindow(percent: 0, resetsAt: nil, windowMinutes: 10_080)

        let stale = provider(weekly: noReset, collectedAt: ago(3 * 3600))
        XCTAssertTrue(stale.freshness(at: now).isStale)
        XCTAssertEqual(stale.displayState(of: noReset, at: now)?.isUnknown, true, "묵은 0%는 지금 0%가 아니다")

        // 한 달을 넘긴 비상식적인 시각(untrusted)도 낡은 것으로 본다
        let untrusted = provider(weekly: noReset, collectedAt: ago(40 * 86400))
        XCTAssertEqual(untrusted.displayState(of: noReset, at: now)?.isUnknown, true)

        let fresh = provider(weekly: noReset, collectedAt: ago(120))
        XCTAssertEqual(fresh.displayState(of: noReset, at: now)?.isUnknown, false)

        // 수집 시각 미상(구버전 수집기)은 판정 유보, 값 미상으로 단정하지 않는다
        let unknownAge = provider(weekly: noReset, collectedAt: nil)
        XCTAssertEqual(unknownAge.displayState(of: noReset, at: now)?.isUnknown, false)
    }

    func testStaleWindowWithKnownResetKeepsItsValue() {
        let future = RateWindow(percent: 62, resetsAt: stamp(now.addingTimeInterval(86400)), windowMinutes: 10_080)
        let stale = provider(weekly: future, collectedAt: ago(3 * 3600))
        let state = stale.displayState(of: future, at: now)
        XCTAssertEqual(state?.isUnknown, false)
        XCTAssertEqual(state?.window.percent, 62)

        // 리셋이 지난 창은 기존대로 다음 창 0% 추정값이다(리셋 시각을 아니까 값 미상이 아니다)
        let passed = RateWindow(percent: 80, resetsAt: stamp(ago(3600)), windowMinutes: 300)
        let estimated = provider(session: passed, weekly: nil, collectedAt: ago(3 * 3600))
            .displayState(of: passed, at: now)
        XCTAssertEqual(estimated?.isEstimated, true)
        XCTAssertEqual(estimated?.isUnknown, false)

        // 신선도 인자 없는 기존 호출은 그대로다
        XCTAssertEqual(RateWindow(percent: 0, resetsAt: nil).displayState(at: now)?.isUnknown, false)
        XCTAssertEqual(RateWindow(percent: 0, resetsAt: nil).displayState(at: now, stale: true)?.isUnknown, true)
    }

    /// 게이지가 값 미상인데 배너나 위젯 대표 숫자만 "한도 도달"이라고 하면 같은 카드가 두 말을 한다.
    func testUnknownWindowDoesNotAssertLimitButStaysDrawable() {
        let fullNoReset = RateWindow(percent: 100, resetsAt: nil, windowMinutes: 10_080)

        let stale = provider(weekly: fullNoReset, collectedAt: ago(3 * 3600))
        XCTAssertNil(stale.providerWideLimit(at: now))
        let primary = stale.primaryDisplayWindow(at: now)
        XCTAssertEqual(primary?.id, "weekly", "줄은 남기고 값 미상으로 그린다, 사라지면 멀쩡하다고 읽힌다")
        XCTAssertEqual(primary.flatMap { stale.displayState(of: $0.window, at: now) }?.isUnknown, true)

        let fresh = provider(weekly: fullNoReset, collectedAt: ago(120))
        XCTAssertNotNil(fresh.providerWideLimit(at: now), "신선한 100%는 리셋 시각을 몰라도 차단이다")
    }

    /// 흐린 묵은 숫자 옆에 밝은 "이 속도면 소진" 예측이 붙으면 숫자를 흐린 의미가 없어진다.
    /// 예측(projectedExhaustion)은 실제 시계를 읽으므로 이 테스트만 고정 시각 대신 지금을 기준으로 창을 만든다.
    func testStaleSnapshotDrawsNoPaceWarning() {
        let live = Date()
        // 7일 중 4.2일 경과에 62%, 페이스 1.03이라 리셋 전 소진 예측이 나온다
        let onPace = RateWindow(
            percent: 62,
            resetsAt: stamp(live.addingTimeInterval(2.8 * 86400)),
            windowMinutes: 10_080
        )
        func state(collectedAt: Date?) -> RateWindowDisplayState? {
            provider(weekly: onPace, collectedAt: collectedAt).displayState(of: onPace, at: live)
        }

        XCTAssertNotNil(state(collectedAt: live.addingTimeInterval(-90))?.paceWarning, "신선한 스냅샷은 기존대로 경고한다")
        XCTAssertNil(state(collectedAt: live.addingTimeInterval(-3 * 86400))?.paceWarning, "묵은 스냅샷")
        XCTAssertNil(state(collectedAt: live.addingTimeInterval(-40 * 86400))?.paceWarning, "믿을 수 없는 시각")
        // 수집 시각 미상은 흐리지 않으니(판정 유보) 경고도 기존대로 둔다
        XCTAssertNotNil(state(collectedAt: nil)?.paceWarning)
        XCTAssertEqual(state(collectedAt: live.addingTimeInterval(-3 * 86400))?.isUnknown, false, "숫자는 흐린 채 남는다")

        // 값 미상, 추정값, 한도 도달은 기존대로 예측 줄이 없다
        XCTAssertNil(RateWindow(percent: 62, resetsAt: nil, windowMinutes: 300).displayState(at: live, stale: true)?.paceWarning)
        XCTAssertNil(RateWindow(percent: 90, resetsAt: stamp(live.addingTimeInterval(-60)), windowMinutes: 300)
            .displayState(at: live, stale: false)?.paceWarning)
        XCTAssertNil(RateWindow(percent: 100, resetsAt: stamp(live.addingTimeInterval(86400)), windowMinutes: 10_080)
            .displayState(at: live, stale: false)?.paceWarning)
        // 신선도 인자 없는 기존 호출은 묵지 않은 것으로 본다
        XCTAssertNotNil(onPace.displayState(at: live)?.paceWarning)
    }

    // MARK: A2 오래된 카드

    private func device(_ id: String, seenAt: Date, status: [String: String]?) -> CollectorDevice {
        CollectorDevice(id: id, label: "PC-\(id)", lastSeenAt: stamp(seenAt), collectStatus: status)
    }

    private func row(
        device: String,
        providerId: String = "claude",
        account: String,
        collectedAt: Date,
        reportedAt: Date? = nil
    ) -> ChargeAPI.ProviderObservationRow {
        ChargeAPI.ProviderObservationRow(
            deviceId: device,
            providerId: providerId,
            account: account,
            payload: provider(
                id: providerId,
                account: account,
                weekly: RateWindow(percent: 0, resetsAt: nil, windowMinutes: 10_080),
                collectedAt: collectedAt
            ),
            collectedAt: stamp(collectedAt),
            lastReportedAt: stamp(reportedAt ?? collectedAt)
        )
    }

    /// 화면에 그려지는 카드 = 병합 결과(페이로드)에 표시 단계의 오래된 카드 정리를 적용한 것
    private func visibleCards(
        _ observations: [ChargeAPI.ProviderObservationRow],
        canonical: [Provider],
        devices: [CollectorDevice],
        now: Date
    ) -> [Provider] {
        ChargeAPI.mergeProviderObservations(observations, canonical: canonical, devices: devices, now: now)
            .hidingOutdatedCards(at: now)
    }

    /// 1.0.2의 실제 증상: 실패 중인 기기의 한 달 묵은 "확인되지 않은 계정" 카드가 은퇴 규칙(실패 중이면
    /// 보존)에 막혀 영영 남았다. 같은 프로바이더에 신선한 카드가 있으면 보이지 않아야 한다.
    func testMonthOldUnidentifiedCardHiddenWhenFresherCardExists() {
        let failing = device("mac", seenAt: ago(60), status: ["claude": "auth_expired;failures=900;since=1786000000"])
        let healthy = device("mini", seenAt: ago(60), status: ["claude": "ok"])
        let observations = [
            row(device: "mac", account: "unknown:mac", collectedAt: ago(28 * 86400)),
            row(device: "mini", account: "acct-a", collectedAt: ago(120))
        ]

        let merged = visibleCards(
            observations, canonical: [], devices: [failing, healthy], now: now
        )
        XCTAssertEqual(merged.map(\.account), ["acct-a"])
    }

    func testOnlyCardForProviderStaysWithOutOfDateWording() {
        let failing = device("mac", seenAt: ago(60), status: ["claude": "error:rate_limited;failures=900"])
        let merged = visibleCards(
            [row(device: "mac", account: "unknown:mac", collectedAt: ago(10 * 86400))],
            canonical: [],
            devices: [failing],
            now: now
        )
        XCTAssertEqual(merged.count, 1, "유일한 카드가 사라지면 그 프로바이더는 멀쩡하다고 읽힌다")
        XCTAssertTrue(merged[0].freshness(at: now).isStale, "대신 기존 오래된 데이터 문구와 흐림이 붙어야 한다")
    }

    func testOutdatedCardOfAnotherProviderIsNotAffected() {
        let d = device("mac", seenAt: ago(60), status: ["claude": "error", "codex": "ok"])
        let merged = visibleCards(
            [
                row(device: "mac", account: "acct-a", collectedAt: ago(9 * 86400)),
                row(device: "mac", providerId: "codex", account: "acct-c", collectedAt: ago(120))
            ],
            canonical: [],
            devices: [d],
            now: now
        )
        XCTAssertEqual(merged.map(\.id).sorted(), ["claude", "codex"])
    }

    func testOlderOfTwoOutdatedCardsIsHiddenAndFreshestRemains() {
        let d = device("mac", seenAt: ago(60), status: ["claude": "error"])
        let merged = visibleCards(
            [
                row(device: "mac", account: "acct-old", collectedAt: ago(20 * 86400)),
                row(device: "mac", account: "acct-newer", collectedAt: ago(9 * 86400))
            ],
            canonical: [],
            devices: [d],
            now: now
        )
        XCTAssertEqual(merged.map(\.account), ["acct-newer"])
    }

    func testCardsWithinLongestWindowAreKept() {
        let d = device("mac", seenAt: ago(60), status: ["claude": "error"])
        let merged = visibleCards(
            [
                row(device: "mac", account: "acct-a", collectedAt: ago(6 * 86400)),
                row(device: "mac", account: "acct-b", collectedAt: ago(120))
            ],
            canonical: [],
            devices: [d],
            now: now
        )
        XCTAssertEqual(merged.compactMap(\.account).sorted(), ["acct-a", "acct-b"])
    }

    /// canonical에만 남은 시각 미상 카드는 더 신선하다고 단정할 근거가 없다. 남의 카드를 밀어내지 않는다.
    /// 반대로 시각을 아는 오래된 canonical 카드는 신선한 관측 카드가 있으면 빠진다.
    func testCanonicalOnlyCardsFollowTheSameRule() {
        let d = device("mac", seenAt: ago(60), status: ["claude": "error"])
        let unknownAgeCanonical = provider(account: "acct-legacy", weekly: nil, collectedAt: nil)
        let keptBoth = visibleCards(
            [row(device: "mac", account: "acct-a", collectedAt: ago(10 * 86400))],
            canonical: [unknownAgeCanonical],
            devices: [d],
            now: now
        )
        XCTAssertEqual(keptBoth.compactMap(\.account).sorted(), ["acct-a", "acct-legacy"])

        let oldCanonical = provider(account: "acct-legacy", weekly: nil, collectedAt: ago(15 * 86400))
        let hidden = visibleCards(
            [row(device: "mac", account: "acct-a", collectedAt: ago(120))],
            canonical: [oldCanonical],
            devices: [d],
            now: now
        )
        XCTAssertEqual(hidden.map(\.account), ["acct-a"])
    }

    /// 수집 시각을 보내지 않는 구버전 수집기(0.1.4 이하)는 캐시를 5분마다 다시 올려 업로드 시각이 늘 "방금"이다.
    /// 업로드 시각은 데이터 나이의 하한일 뿐이라, 그 카드가 더 신선하다는 근거가 못 된다.
    /// 반대로 업로드마저 7일 넘게 끊긴 카드는 적어도 그만큼 묵었으니 신선한 카드가 있으면 빠진다.
    func testUploadTimeNeverMakesACardFresher() {
        func unstamped(device: String, account: String, reportedAt: Date) -> ChargeAPI.ProviderObservationRow {
            ChargeAPI.ProviderObservationRow(
                deviceId: device,
                providerId: "claude",
                account: account,
                payload: provider(
                    account: account,
                    weekly: RateWindow(percent: 10, resetsAt: nil, windowMinutes: 10_080),
                    collectedAt: nil
                ),
                collectedAt: nil,
                lastReportedAt: stamp(reportedAt)
            )
        }
        let failing = device("mac", seenAt: ago(60), status: ["claude": "auth_expired;failures=900;since=1786000000"])
        let stampedOld = row(device: "mac", account: "acct-a", collectedAt: ago(8 * 86400), reportedAt: ago(60))

        // 살아 있는 구버전 기기, 카드는 나이 미상으로 그려진다
        let live = device("old", seenAt: ago(60), status: nil)
        let withLive = visibleCards(
            [unstamped(device: "old", account: "acct-b", reportedAt: ago(60)), stampedOld],
            canonical: [], devices: [live, failing], now: now
        )
        XCTAssertEqual(withLive.compactMap(\.account).sorted(), ["acct-a", "acct-b"])
        XCTAssertNil(withLive.first { $0.account == "acct-b" }?.collectedAt)

        // 이틀 전에 꺼진 구버전 기기, 카드는 업로드 시각을 나이 하한으로 보여 주지만 더 신선하다는 뜻은 아니다
        let offline = device("old", seenAt: ago(2 * 86400), status: nil)
        let withOffline = visibleCards(
            [unstamped(device: "old", account: "acct-b", reportedAt: ago(2 * 86400)), stampedOld],
            canonical: [], devices: [offline, failing], now: now
        )
        XCTAssertEqual(withOffline.compactMap(\.account).sorted(), ["acct-a", "acct-b"])
        // 병합이 하한임을 표시해 둬야 표시 단계가 스탬프와 구분할 수 있다
        XCTAssertEqual(withOffline.first { $0.account == "acct-b" }?.collectedAtIsUploadFloor, true)
        XCTAssertNil(withOffline.first { $0.account == "acct-b" }?.stampedDate)
        XCTAssertNil(withOffline.first { $0.account == "acct-a" }?.collectedAtIsUploadFloor)

        // 업로드가 9일 전에 끊긴 카드는 적어도 9일 묵었다, 신선한 스탬프 카드가 있으면 빠진다
        let longGone = device("old", seenAt: ago(9 * 86400), status: nil)
        let healthy = device("mini", seenAt: ago(60), status: ["claude": "ok"])
        let withFresh = visibleCards(
            [
                unstamped(device: "old", account: "acct-b", reportedAt: ago(9 * 86400)),
                row(device: "mini", account: "acct-c", collectedAt: ago(120))
            ],
            canonical: [], devices: [longGone, healthy], now: now
        )
        XCTAssertEqual(withFresh.compactMap(\.account), ["acct-c"])
    }

    /// 시계가 크게 앞선 기기의 미래 수집 시각은 믿을 수 없는 값(untrusted)이라 남의 카드를 밀어내지 않는다.
    /// 봐주는 범위(futureSlack) 안의 미래 시각은 기존대로 더 신선한 카드다.
    func testFarFutureStampDoesNotHideOtherCards() {
        let skewed = device("skewed", seenAt: ago(60), status: ["claude": "error"])
        let failing = device("mac", seenAt: ago(60), status: ["claude": "error"])
        let stampedOld = row(device: "mac", account: "acct-a", collectedAt: ago(8 * 86400), reportedAt: ago(60))

        let farFuture = visibleCards(
            [
                row(device: "skewed", account: "acct-b", collectedAt: now.addingTimeInterval(3 * 86400), reportedAt: ago(60)),
                stampedOld
            ],
            canonical: [], devices: [skewed, failing], now: now
        )
        XCTAssertEqual(farFuture.compactMap(\.account).sorted(), ["acct-a", "acct-b"])

        let slightlyAhead = visibleCards(
            [
                row(device: "skewed", account: "acct-b", collectedAt: now.addingTimeInterval(10 * 60), reportedAt: ago(60)),
                stampedOld
            ],
            canonical: [], devices: [skewed, failing], now: now
        )
        XCTAssertEqual(slightlyAhead.compactMap(\.account), ["acct-b"])
    }

    // MARK: D10 표시 전용 정리

    /// 병합 결과(페이로드)에는 가려질 카드도 남는다. 스트릭 보호의 계정 목록은 이 목록에서 만든다
    /// (ContentView.protectedPeriods). 가려진 계정까지 빼면, 그 계정이 막히지 않았던 날이 보호일로 바뀐다.
    func testOutdatedCardHidingIsPresentationOnly() {
        let failing = device("mac", seenAt: ago(60), status: ["claude": "auth_expired;failures=900;since=1786000000"])
        let healthy = device("mini", seenAt: ago(60), status: ["claude": "ok"])
        let observations = [
            row(device: "mac", account: "acct-old", collectedAt: ago(9 * 86400)),
            row(device: "mini", account: "acct-a", collectedAt: ago(120))
        ]
        let merged = ChargeAPI.mergeProviderObservations(
            observations, canonical: [], devices: [failing, healthy], now: now
        )
        XCTAssertEqual(merged.compactMap(\.account), ["acct-a", "acct-old"], "병합은 카드를 숨기지 않는다")
        XCTAssertEqual(merged.hidingOutdatedCards(at: now).compactMap(\.account), ["acct-a"])

        // 구버전 차단 행(observedAccounts 없음)은 현재 계정 집합으로 완결성을 판정한다
        let blockedA = QuotaBlock(
            providerId: "claude",
            account: "acct-a",
            windowKind: "weekly",
            resetAt: stamp(now.addingTimeInterval(86400)),
            firstSeenAt: stamp(ago(2 * 86400)),
            lastSeenAt: stamp(ago(60)),
            clearedAt: nil
        )
        let unfiltered = Set(merged.filter { $0.id == "claude" }.compactMap(\.account))
        let filtered = Set(merged.hidingOutdatedCards(at: now).filter { $0.id == "claude" }.compactMap(\.account))
        XCTAssertTrue(StreakProtection.protectedPeriods(
            providerId: "claude", accounts: unfiltered, blocks: [blockedA], now: now, historyDays: 1
        ).isEmpty, "막히지 않은 acct-old가 있으니 보호일이 아니다")
        XCTAssertFalse(StreakProtection.protectedPeriods(
            providerId: "claude", accounts: filtered, blocks: [blockedA], now: now, historyDays: 1
        ).isEmpty, "걸러진 목록을 쓰면 거짓 보호일이 된다(그래서 쓰지 않는다)")
    }

    private func card(
        _ account: String,
        collectedAt: Date?,
        uploadFloor: Bool = false,
        session: RateWindow? = nil,
        weekly: RateWindow? = RateWindow(percent: 10, resetsAt: nil, windowMinutes: 10_080),
        extras: [ExtraWindow]? = nil
    ) -> Provider {
        Provider(
            id: "claude",
            name: "Claude",
            plan: nil,
            session: session,
            weekly: weekly,
            extras: extras,
            status: nil,
            account: account,
            collectedAt: collectedAt.map(stamp),
            collectedAtIsUploadFloor: uploadFloor ? true : nil
        )
    }

    /// 경계는 7일과 그 카드가 가진 가장 긴 창 중 긴 쪽이다. 월간 창을 가진 카드는 열흘 묵어도 그 창에 대해 말해준다.
    func testLongestWindowExtendsOutdatedAge() {
        let monthly = [ExtraWindow(name: "Monthly", window: RateWindow(percent: 50, resetsAt: nil, windowMinutes: 43_200))]
        XCTAssertEqual(card("a", collectedAt: now).outdatedCardAge, 7 * 86400)
        XCTAssertEqual(card("a", collectedAt: now, extras: monthly).outdatedCardAge, 30 * 86400)
        XCTAssertEqual(card("a", collectedAt: now, session: RateWindow(percent: 1, resetsAt: nil, windowMinutes: 300), weekly: nil).outdatedCardAge, 7 * 86400)
        XCTAssertEqual(card("a", collectedAt: now, weekly: nil).outdatedCardAge, 7 * 86400, "창이 없으면 기본 7일")
        XCTAssertEqual(card("a", collectedAt: now, weekly: RateWindow(percent: 1, resetsAt: nil, windowMinutes: -99_999)).outdatedCardAge, 7 * 86400)

        let fresh = card("fresh", collectedAt: ago(120))
        XCTAssertEqual(
            [card("monthly", collectedAt: ago(10 * 86400), extras: monthly), fresh].hidingOutdatedCards(at: now).compactMap(\.account),
            ["monthly", "fresh"]
        )
        XCTAssertEqual(
            [card("weekly", collectedAt: ago(10 * 86400)), fresh].hidingOutdatedCards(at: now).compactMap(\.account),
            ["fresh"]
        )
        XCTAssertEqual(
            [card("monthly", collectedAt: ago(31 * 86400), extras: monthly), fresh].hidingOutdatedCards(at: now).compactMap(\.account),
            ["fresh"]
        )
        // 경계와 같은 나이는 "넘긴" 것이 아니다
        XCTAssertEqual([card("edge", collectedAt: ago(7 * 86400)), fresh].hidingOutdatedCards(at: now).count, 2)
    }

    /// 다른 카드가 "확실히 더 늦은, 아는" 수집 시각을 가질 때만 가린다.
    func testOnlyStrictlyNewerKnownDataHidesACard() {
        let old = ago(9 * 86400)
        XCTAssertEqual([card("a", collectedAt: old), card("b", collectedAt: old)].hidingOutdatedCards(at: now).count, 2, "같은 시각은 더 신선한 것이 아니다")
        XCTAssertEqual(
            [card("a", collectedAt: old), card("b", collectedAt: old.addingTimeInterval(1))].hidingOutdatedCards(at: now).compactMap(\.account),
            ["b"]
        )
        XCTAssertEqual(
            [card("a", collectedAt: old), card("b", collectedAt: ago(60), uploadFloor: true)].hidingOutdatedCards(at: now).count,
            2,
            "업로드 시각 하한은 더 신선하다는 근거가 못 된다"
        )
        XCTAssertEqual([card("a", collectedAt: old), card("b", collectedAt: nil)].hidingOutdatedCards(at: now).count, 2)
    }

    /// 캐시(App Group 파일)를 거쳐도 하한 표시가 유지되고, 표시가 없는 구버전 캐시는 스탬프로 읽힌다.
    func testUploadFloorFlagSurvivesPayloadCache() throws {
        let floored = card("a", collectedAt: ago(9 * 86400), uploadFloor: true)
        let decoded = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(floored))
        XCTAssertEqual(decoded.collectedAtIsUploadFloor, true)
        XCTAssertNil(decoded.stampedDate)
        XCTAssertNotNil(decoded.collectedDate)

        let legacy = try JSONDecoder().decode(
            Provider.self,
            from: Data(#"{"id":"claude","name":"Claude","collectedAt":"2026-09-01T00:00:00Z"}"#.utf8)
        )
        XCTAssertNil(legacy.collectedAtIsUploadFloor)
        XCTAssertNotNil(legacy.stampedDate)
    }

    /// 리셋 알림은 화면에서 가린 카드의 창과 이미 리셋이 지난 창을 예약하지 않는다.
    func testResetAlertsSkipHiddenCardsAndPastResets() {
        let hiddenOld = card(
            "old",
            collectedAt: ago(10 * 86400),
            session: RateWindow(percent: 95, resetsAt: stamp(now.addingTimeInterval(3600)), windowMinutes: 300),
            weekly: nil
        )
        let fresh = card(
            "fresh",
            collectedAt: ago(120),
            session: RateWindow(percent: 90, resetsAt: stamp(ago(60)), windowMinutes: 300),
            weekly: RateWindow(percent: 95, resetsAt: stamp(now.addingTimeInterval(86400)), windowMinutes: 10_080)
        )

        let planned = ResetNotifications.plannedAlerts(providers: [hiddenOld, fresh], warnThreshold: 70, muted: [], now: now)
        XCTAssertEqual(planned.map(\.id), ["reset-claude#fresh-weekly"])
        XCTAssertEqual(planned.first?.reset, now.addingTimeInterval(86400))

        // 가려지지 않은(그 프로바이더의 유일한) 오래된 카드는 기존대로 예약한다
        XCTAssertEqual(
            ResetNotifications.plannedAlerts(providers: [hiddenOld], warnThreshold: 70, muted: [], now: now).map(\.id),
            ["reset-claude#old-session"]
        )
        // 음소거, 임계값 미만은 기존대로 뺀다
        XCTAssertTrue(ResetNotifications.plannedAlerts(providers: [fresh], warnThreshold: 70, muted: ["claude"], now: now).isEmpty)
        XCTAssertTrue(ResetNotifications.plannedAlerts(providers: [fresh], warnThreshold: 96, muted: [], now: now).isEmpty)
    }

    // MARK: A1 대표 창

    /// 쉬고 있는 5시간 세션은 리셋 시각이 없다(수집기의 five_hour 창). 요청 제한 대기로 스냅샷이 20분을 넘기면
    /// 그 세션은 값 미상인데, 대표 창으로 세션을 고르면 주간 값을 알면서도 잠금화면과 인라인 위젯이
    /// 자리표시자만 그리고, 대표 프로바이더를 고를 때도 가장 낮게 밀린다.
    func testStaleIdleSessionYieldsPrimaryToKnownWeekly() {
        let idleSession = RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300)
        let weekly = RateWindow(percent: 62, resetsAt: stamp(now.addingTimeInterval(2 * 86400)), windowMinutes: 10_080)

        let stale = provider(session: idleSession, weekly: weekly, collectedAt: ago(40 * 60))
        let primary = stale.primaryDisplayWindow(at: now)
        XCTAssertEqual(primary?.id, "weekly")
        XCTAssertEqual(primary?.window.percent, 62)
        XCTAssertEqual(primary.flatMap { stale.displayState(of: $0.window, at: now) }?.isUnknown, false)

        // 신선한 스냅샷은 기존대로 세션이 대표다
        XCTAssertEqual(
            provider(session: idleSession, weekly: weekly, collectedAt: ago(120)).primaryDisplayWindow(at: now)?.id,
            "session"
        )
        // 주간도 값을 모르거나 없으면 세션을 그대로 둔다, 대표 창이 사라지면 "No data"가 된다
        let weeklyUnknown = RateWindow(percent: 30, resetsAt: nil, windowMinutes: 10_080)
        XCTAssertEqual(
            provider(session: idleSession, weekly: weeklyUnknown, collectedAt: ago(40 * 60)).primaryDisplayWindow(at: now)?.id,
            "session"
        )
        XCTAssertEqual(
            provider(session: idleSession, weekly: nil, collectedAt: ago(40 * 60)).primaryDisplayWindow(at: now)?.id,
            "session"
        )
    }
}
