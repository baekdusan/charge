import XCTest
@testable import Charge

/// 수집 상태 문자열("종류;키=값"), 수집기 메타데이터 키("_collector"), 수집기 버전 규칙.
/// 구버전 앱은 접두사만 보므로 종류는 호환을 지키고, 파라미터는 순서와 무관하게 읽어야 한다.
final class CollectorStatusTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date(timeIntervalSince1970: 1_789_344_000)

    private func stamp(_ date: Date) -> String { iso.string(from: date) }

    /// 화면과 같은 경로(기기의 collectIssues)로 만든다. 만료 문구가 그 기기의 수집기 버전에 따라 달라지기 때문이다.
    private func issue(_ status: String, provider: String = "claude", version: String? = "0.2.0") -> CollectorDevice.CollectIssue {
        let issues = device(status: [provider: status], version: version).collectIssues
        XCTAssertEqual(issues.count, 1, status)
        return issues.first ?? .init(providerId: provider, providerName: provider.capitalized, status: status)
    }

    private func device(
        _ id: String = "mac",
        seenAt: Date? = nil,
        status: [String: String]?,
        version: String? = nil
    ) -> CollectorDevice {
        CollectorDevice(
            id: id,
            label: "PC-\(id)",
            lastSeenAt: stamp(seenAt ?? now),
            collectStatus: status,
            collectorVersion: version
        )
    }

    // MARK: 파싱

    func testParsesKindAndParametersInAnyOrder() {
        let status = CollectStatus("error:rate_limited;retry_at=1789344600;failures=3;since=1789343000")
        XCTAssertEqual(status.kind, "error:rate_limited")
        XCTAssertTrue(status.isRateLimited)
        XCTAssertTrue(status.isIssue)
        XCTAssertEqual(status.retryAt, Date(timeIntervalSince1970: 1_789_344_600))
        XCTAssertEqual(status.consecutiveFailures, 3)
        XCTAssertEqual(status.parameter("since"), "1789343000")

        // 순서가 바뀌어도 같은 값
        let reordered = CollectStatus("error:rate_limited;failures=3;since=1789343000;retry_at=1789344600")
        XCTAssertEqual(reordered, status)
    }

    func testMalformedAndUnknownParametersAreIgnored() {
        let status = CollectStatus("auth_expired;;failures;=5;since=;future_key=x=y;failures=abc;failures=7")
        XCTAssertEqual(status.kind, "auth_expired")
        // 먼저 온 failures=abc가 이긴다, 숫자가 아니므로 횟수는 모른다
        XCTAssertNil(status.consecutiveFailures)
        XCTAssertNil(status.parameter("since"))
        XCTAssertEqual(status.parameter("future_key"), "x=y")
        XCTAssertNil(status.retryAt)

        XCTAssertNil(CollectStatus("error:rate_limited;retry_at=soon").retryAt)
        XCTAssertNil(CollectStatus("error:rate_limited;retry_at=-5").retryAt)
        XCTAssertNil(CollectStatus("error:rate_limited;retry_at=nan").retryAt)
        XCTAssertEqual(CollectStatus("").kind, "")
        XCTAssertFalse(CollectStatus("").isIssue)
    }

    func testKindsKeepPrefixCompatibility() {
        XCTAssertTrue(CollectStatus("auth_expired").isAuthExpired)
        XCTAssertFalse(CollectStatus("auth_expired").isRevoked)
        XCTAssertTrue(CollectStatus("auth_expired:revoked;failures=2").isAuthExpired)
        XCTAssertTrue(CollectStatus("auth_expired:revoked;failures=2").isRevoked)
        XCTAssertTrue(CollectStatus("error:access_denied").isAccessDenied)
        XCTAssertTrue(CollectStatus("error:credentials_missing").needsSetup)
        XCTAssertTrue(CollectStatus("error").isIssue)
        XCTAssertFalse(CollectStatus("stale").isIssue)
        XCTAssertFalse(CollectStatus("some_future_state").isIssue)
    }

    // MARK: shared

    func testSharedIsHealthyAndNeverAWarning() {
        let shared = CollectStatus("shared")
        XCTAssertTrue(shared.isShared)
        XCTAssertTrue(shared.isHealthy)
        XCTAssertFalse(shared.isIssue)
        XCTAssertTrue(CollectStatus("ok").isHealthy)
        XCTAssertFalse(CollectStatus("error:rate_limited").isHealthy)

        let d = device(status: ["claude": "shared", "codex": "ok"])
        XCTAssertTrue(d.collectIssues.isEmpty)
        XCTAssertTrue(d.visibleCollectIssues(hidden: []).isEmpty)
        XCTAssertEqual(d.status(for: "claude")?.isHealthy, true)
    }

    /// shared인 기기는 요청을 건너뛰어 새 관측을 만들지 않는다. 그 기기의 옛 관측은 ok와 똑같이
    /// 은퇴해야 한다, 보존하면 같은 계정을 실제로 올리는 기기의 값과 겹쳐 낡은 행이 남는다.
    func testSharedRetiresOldObservationLikeOK() {
        let staleReport = now.addingTimeInterval(-40 * 60)
        func merged(status: String) -> [Provider] {
            ChargeAPI.mergeProviderObservations(
                [ChargeAPI.ProviderObservationRow(
                    deviceId: "mac",
                    providerId: "claude",
                    account: "acct-a",
                    payload: Provider(
                        id: "claude", name: "Claude", plan: nil,
                        session: nil,
                        weekly: RateWindow(percent: 40, resetsAt: stamp(now.addingTimeInterval(86400)), windowMinutes: 10_080),
                        extras: nil, status: nil, account: "acct-a",
                        collectedAt: stamp(staleReport)
                    ),
                    collectedAt: stamp(staleReport),
                    lastReportedAt: stamp(staleReport)
                )],
                canonical: [],
                devices: [device(status: ["claude": status])],
                now: now
            )
        }
        XCTAssertTrue(merged(status: "ok").isEmpty)
        XCTAssertTrue(merged(status: "shared").isEmpty)
        XCTAssertTrue(merged(status: "shared;failures=0").isEmpty)
        // 실패 중인 기기는 마지막 정상 관측을 보존한다(기존 규칙)
        XCTAssertEqual(merged(status: "error:rate_limited;retry_at=1789345000;failures=4;since=1789340000").count, 1)
    }

    // MARK: "_" 메타데이터 키

    func testUnderscoreKeysAreNotProviders() {
        let onlyMeta = device(status: ["_collector": "0.2.0", "_anything": "error"])
        XCTAssertTrue(onlyMeta.collectIssues.isEmpty, "메타데이터 값이 error처럼 보여도 경고가 아니다")
        XCTAssertTrue(onlyMeta.hasNoProviders, "메타데이터만 있는 맵은 프로바이더가 없는 기기다")
        XCTAssertFalse(onlyMeta.isLegacyCollector)
        XCTAssertEqual(onlyMeta.providerStatuses ?? ["x": "y"], [:])
        XCTAssertNil(onlyMeta.status(for: "_collector"))

        let mixed = device(status: ["_collector": "0.2.0", "claude": "auth_expired;failures=1"])
        XCTAssertEqual(mixed.collectIssues.map(\.providerId), ["claude"])
        XCTAssertFalse(mixed.hasNoProviders)
    }

    /// 은퇴 판정에서도 "_" 키는 프로바이더 상태가 아니다. 메타데이터만 있는 맵은 "이번엔 그 소스를
    /// 열거하지 못했다"로 읽혀 마지막 관측을 보존해야 한다(구버전처럼 20분 규칙으로 지우지 않는다).
    func testUnderscoreOnlyStatusMapPreservesObservation() {
        let reported = now.addingTimeInterval(-40 * 60)
        let merged = ChargeAPI.mergeProviderObservations(
            [ChargeAPI.ProviderObservationRow(
                deviceId: "mac",
                providerId: "claude",
                account: "acct-a",
                payload: Provider(
                    id: "claude", name: "Claude", plan: nil, session: nil,
                    weekly: RateWindow(percent: 40, resetsAt: stamp(now.addingTimeInterval(86400)), windowMinutes: 10_080),
                    extras: nil, status: nil, account: "acct-a", collectedAt: stamp(reported)
                ),
                collectedAt: stamp(reported),
                lastReportedAt: stamp(reported)
            )],
            canonical: [],
            devices: [device(status: ["_collector": "0.2.0"])],
            now: now
        )
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: 안내 문구

    func testExpiredTokenAsksToOpenClaudeCodeNotToSignIn() {
        let expired = issue("auth_expired;failures=6;since=1789340000")
        XCTAssertEqual(expired.actionHint(at: now), String(localized: "Open Claude Code on this PC once"))
        XCTAssertNotEqual(expired.actionHint(at: now), String(localized: "Try signing in again in \("Claude")"))
        XCTAssertEqual(
            expired.guidance(at: now),
            String(localized: "Claude Code's sign-in on this PC has expired. Open Claude Code on this PC once and it refreshes automatically. You don't need to sign in again.")
        )

        let revoked = issue("auth_expired:revoked;failures=1;since=1789340000")
        XCTAssertEqual(revoked.actionHint(at: now), String(localized: "Sign in again in Claude Code (/login)"))
        XCTAssertNotEqual(revoked.guidance(at: now), expired.guidance(at: now))

        // Claude 밖의 프로바이더는 기존 일반 문구를 유지한다
        let codex = issue("auth_expired", provider: "codex")
        XCTAssertEqual(codex.actionHint(at: now), String(localized: "Try signing in again in \(codex.providerName)"))
        XCTAssertNil(issue("error").actionHint(at: now))
    }

    /// 0.2.0 전 수집기는 401을 전부 "auth_expired"로 보냈다(폐기된 로그인 포함). 그런 기기에 "다시 로그인하지
    /// 않아도 된다"고 단언하면 로그인이 폐기된 사용자는 할 일을 잃는다. 먼저 열어 보고, 로그인을 요구하면 /login.
    func testExpiredWordingStaysSoftWhenCollectorCannotTellRevoked() {
        let firmGuidance = String(localized: "Claude Code's sign-in on this PC has expired. Open Claude Code on this PC once and it refreshes automatically. You don't need to sign in again.")
        let softGuidance = String(localized: "Charge couldn't use Claude Code's sign-in on this PC. Opening Claude Code on this PC once usually refreshes it. If Claude Code asks you to sign in, run /login.")
        let softHint = String(localized: "Open Claude Code on this PC once (run /login if asked)")

        for version in [nil, "0.1.9", "0.2.0-beta.1", "garbage"] as [String?] {
            let legacy = issue("auth_expired;failures=7;since=1789340000", version: version)
            XCTAssertEqual(legacy.guidance(at: now), softGuidance, version ?? "nil")
            XCTAssertEqual(legacy.actionHint(at: now), softHint, version ?? "nil")
        }
        XCTAssertEqual(issue("auth_expired", version: "0.3.0").guidance(at: now), firmGuidance)
        // 컬럼을 모르는 서버가 상태 맵에 남긴 "_collector"로만 버전을 알아도 새 수집기로 본다
        let fallback = device(status: ["claude": "auth_expired", "_collector": "0.2.0"]).collectIssues.first
        XCTAssertEqual(fallback?.guidance(at: now), firmGuidance)
        XCTAssertEqual(fallback?.actionHint(at: now), String(localized: "Open Claude Code on this PC once"))
        // 폐기는 0.2.0 이상만 보내는 상태라 버전과 무관하게 다시 로그인 안내다
        XCTAssertEqual(
            issue("auth_expired:revoked", version: nil).actionHint(at: now),
            String(localized: "Sign in again in Claude Code (/login)")
        )
    }

    func testRateLimitMentionsRetryTimeOnlyWhenPending() {
        let base = String(localized: "The usage service is limiting requests. Charge will retry automatically. This does not mean your subscription has ended.")
        let retry = now.addingTimeInterval(25 * 60)
        let pending = issue("error:rate_limited;retry_at=\(Int(retry.timeIntervalSince1970));failures=5;since=1789340000")
        let time = CollectStatus.retryTimeText(retry, now: now)

        XCTAssertEqual(pending.parsed.pendingRetry(at: now), retry)
        XCTAssertTrue(pending.guidance(at: now).hasPrefix(base), "기존 요청 제한 안내는 그대로 둔다")
        XCTAssertTrue(pending.guidance(at: now).contains(time))
        XCTAssertEqual(pending.actionHint(at: now), String(localized: "Next try around \(time)"))

        // 이미 지난 시각, 시각 미상, 비상식적으로 먼 시각은 말하지 않는다
        XCTAssertEqual(pending.guidance(at: retry.addingTimeInterval(1)), base)
        XCTAssertNil(pending.actionHint(at: retry))
        XCTAssertEqual(issue("error:rate_limited;failures=5").guidance(at: now), base)
        let farFuture = issue("error:rate_limited;retry_at=\(Int(now.timeIntervalSince1970) + 3 * 86400)")
        XCTAssertNil(farFuture.parsed.pendingRetry(at: now))
        XCTAssertEqual(farFuture.guidance(at: now), base)
    }

    /// 수집기는 Retry-After를 86400초로 자른 뒤 60초를 더하므로 retry_at은 최대 now+86460이다.
    /// 그 끝값과 PC 시계가 조금 앞선 경우까지는 시각을 안내하고, 밀리초 같은 단위 오류만 버린다.
    func testRetryAtAcceptsTheCollectorsFullRange() {
        let seconds = Int(now.timeIntervalSince1970)
        let longest = Date(timeIntervalSince1970: TimeInterval(seconds + 86460))
        let capped = issue("error:rate_limited;retry_at=\(seconds + 86460);failures=1;since=\(seconds)")
        XCTAssertEqual(CollectStatus.maxRetryDelay, 86460)
        XCTAssertEqual(capped.parsed.pendingRetry(at: now), longest)
        XCTAssertEqual(capped.actionHint(at: now), String(localized: "Next try around \(CollectStatus.retryTimeText(longest, now: now))"))

        let skewed = seconds + 86460 + Int(ChargeFreshness.futureSlack)
        XCTAssertNotNil(CollectStatus("error:rate_limited;retry_at=\(skewed)").pendingRetry(at: now))
        XCTAssertNil(CollectStatus("error:rate_limited;retry_at=\(skewed + 1)").pendingRetry(at: now))
        XCTAssertNil(CollectStatus("error:rate_limited;retry_at=\(seconds * 1000 + 600_000)").pendingRetry(at: now), "밀리초 값")
    }

    // MARK: 수집기 버전

    func testCollectorVersionComparison() {
        func v(_ raw: String) -> CollectorVersion? { CollectorVersion(raw) }
        XCTAssertLessThan(v("0.1.9")!, v("0.2.0")!)
        XCTAssertEqual(v("0.2.0"), v("0.2.0"))
        XCTAssertGreaterThan(v("0.10.0")!, v("0.2.0")!, "숫자 비교여야 한다, 문자열 비교면 0.10 < 0.2")
        XCTAssertGreaterThan(v("1.0.0")!, v("0.99.99")!)
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertEqual(v(" v0.2.1 "), v("0.2.1"))
        XCTAssertEqual(v("0.2.0+build.7"), v("0.2.0"))
        XCTAssertLessThan(v("0.2.0-beta.1")!, v("0.2.0")!)
        XCTAssertGreaterThan(v("0.2.1-beta")!, v("0.2.0")!)

        for garbage in ["", "abc", "0.2.x", "1..2", "1.2.3.4", "-1.0.0", "0.2.0 beta", "١.٢.٣"] {
            XCTAssertNil(v(garbage), garbage)
        }
    }

    func testUpdateHintForTrackingDevicesBelowSelfUpdatingCollector() {
        XCTAssertTrue(device(status: ["claude": "ok"], version: "0.1.9").needsCollectorUpdate(at: now))
        XCTAssertTrue(device(status: ["claude": "ok"], version: nil).needsCollectorUpdate(at: now), "버전 미상은 0.2.0 미만으로 본다")
        XCTAssertTrue(device(status: nil, version: nil).needsCollectorUpdate(at: now))
        XCTAssertTrue(device(status: ["claude": "ok"], version: "garbage").needsCollectorUpdate(at: now))
        XCTAssertFalse(device(status: ["claude": "ok"], version: "0.2.0").needsCollectorUpdate(at: now))
        XCTAssertFalse(device(status: ["claude": "ok"], version: "0.3.1").needsCollectorUpdate(at: now))

        // 컬럼이 없는 서버가 상태 맵에 그대로 남긴 "_collector"로 폴백한다
        let fallback = device(status: ["claude": "ok", "_collector": "0.2.0"], version: nil)
        XCTAssertEqual(fallback.reportedCollectorVersion, "0.2.0")
        XCTAssertFalse(fallback.needsCollectorUpdate(at: now))
        // 둘 다 있으면 서버 컬럼이 우선이다
        let both = device(status: ["claude": "ok", "_collector": "0.2.0"], version: "0.1.9")
        XCTAssertEqual(both.reportedCollectorVersion, "0.1.9")
        XCTAssertTrue(both.needsCollectorUpdate(at: now))
        XCTAssertEqual(device(status: ["_collector": "0.2.0"], version: "  ").reportedCollectorVersion, "0.2.0")

        // 업로드가 끊긴 기기에는 말하지 않는다
        let offline = device(seenAt: now.addingTimeInterval(-3600), status: ["claude": "ok"], version: "0.1.9")
        XCTAssertFalse(offline.needsCollectorUpdate(at: now))
    }

    /// 새 컬럼이 없는 캐시(구버전 앱이 저장한 payload)도 그대로 읽혀야 한다.
    func testDeviceDecodesWithAndWithoutCollectorVersion() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let withVersion = try decoder.decode(
            CollectorDevice.self,
            from: Data(#"{"id":"a","label":"Mac","last_seen_at":null,"collect_status":{"claude":"shared"},"collector_version":"0.2.0"}"#.utf8)
        )
        XCTAssertEqual(withVersion.collectorVersion, "0.2.0")
        let legacy = try decoder.decode(
            CollectorDevice.self,
            from: Data(#"{"id":"a","label":"Mac","last_seen_at":null}"#.utf8)
        )
        XCTAssertNil(legacy.collectorVersion)
        XCTAssertNil(legacy.collectStatus)
    }

    // MARK: D5 "_" 키만 남은 맵

    /// "_" 키를 걷어낸 뒤 비는 맵은 모든 판정에서 {}와 똑같다. 프로바이더 없음 판정도, 상태 미상(구버전)
    /// 판정도, 경고, "정상인 다른 PC", 은퇴 판정도 {}와 같은 답을 해야 한다.
    func testUnderscoreOnlyMapBehavesExactlyLikeEmptyMap() {
        let empty = device(status: [:], version: "0.2.0")
        let metaOnly = device(status: ["_collector": "0.2.0"], version: "0.2.0")

        XCTAssertEqual(metaOnly.providerStatuses, empty.providerStatuses)
        XCTAssertEqual(metaOnly.hasNoProviders, empty.hasNoProviders)
        XCTAssertEqual(metaOnly.isLegacyCollector, empty.isLegacyCollector)
        XCTAssertFalse(metaOnly.isLegacyCollector, "상태를 보내는 수집기다, 상태 미상으로 읽지 않는다")
        XCTAssertEqual(metaOnly.collectIssues.map(\.providerId), empty.collectIssues.map(\.providerId))
        XCTAssertEqual(metaOnly.needsCollectorUpdate(at: now), empty.needsCollectorUpdate(at: now))
        XCTAssertNil(metaOnly.status(for: "claude"))
        XCTAssertNil(metaOnly.status(for: "_collector"))
        // 상태 맵 자체가 없는(null) 기기만 상태 미상이다
        XCTAssertTrue(device(status: nil).isLegacyCollector)
        XCTAssertFalse(device(status: nil).hasNoProviders)

        let failing = device("other", status: ["claude": "error:rate_limited;failures=6;since=1789340000"])
        XCTAssertEqual(
            failing.hasHealthyPeer(for: "claude", among: [failing, metaOnly], at: now),
            failing.hasHealthyPeer(for: "claude", among: [failing, empty], at: now)
        )

        func mergedCount(with statusDevice: CollectorDevice) -> Int {
            let reported = now.addingTimeInterval(-40 * 60)
            return ChargeAPI.mergeProviderObservations(
                [ChargeAPI.ProviderObservationRow(
                    deviceId: statusDevice.id,
                    providerId: "claude",
                    account: "acct-a",
                    payload: Provider(
                        id: "claude", name: "Claude", plan: nil, session: nil,
                        weekly: RateWindow(percent: 40, resetsAt: stamp(now.addingTimeInterval(86400)), windowMinutes: 10_080),
                        extras: nil, status: nil, account: "acct-a", collectedAt: stamp(reported)
                    ),
                    collectedAt: stamp(reported),
                    lastReportedAt: stamp(reported)
                )],
                canonical: [],
                devices: [statusDevice],
                now: now
            ).count
        }
        XCTAssertEqual(mergedCount(with: metaOnly), mergedCount(with: empty))
    }

    // MARK: D6 확인된 로그인 문제, 정상인 다른 PC, 복구 카드 문구

    /// Claude 만료/폐기는 기다려도 낫지 않는다. 5회, 20분 문턱 없이 기기 줄이 바로 "확인 필요"와 조치를 말한다.
    /// 요청 제한과 그 밖의 오류는 문턱을 그대로 둔다.
    func testConfirmedClaudeAuthProblemNeedsAttentionImmediately() {
        let justStarted = Int(now.timeIntervalSince1970) - 60
        for status in [
            "auth_expired;failures=1;since=\(justStarted)",
            "auth_expired:revoked;failures=1;since=\(justStarted)",
            "auth_expired",
            "auth_expired:revoked"
        ] {
            let expired = issue(status)
            XCTAssertTrue(expired.needsActionNow, status)
            XCTAssertEqual(expired.headline(lastAttempt: now), .needsAttention, status)
            XCTAssertNotNil(expired.actionHint(at: now), status)
            XCTAssertFalse(expired.isPersistent(lastAttempt: now), "문턱 판정 자체는 그대로다: \(status)")
        }
        // 구버전 수집기(폐기를 구분 못 함)도 바로 알리되 문구는 부드럽게 둔다
        let legacy = issue("auth_expired;failures=1;since=\(justStarted)", version: "0.1.9")
        XCTAssertEqual(legacy.headline(lastAttempt: now), .needsAttention)
        XCTAssertEqual(legacy.actionHint(at: now), String(localized: "Open Claude Code on this PC once (run /login if asked)"))

        let retry = Int(now.timeIntervalSince1970) + 600
        XCTAssertEqual(issue("error:rate_limited;retry_at=\(retry);deferred=1;failures=4;since=\(justStarted)").headline(lastAttempt: now), .retrying)
        XCTAssertEqual(issue("error:access_denied;failures=1;since=\(justStarted)").headline(lastAttempt: now), .retrying)
        XCTAssertEqual(issue("error").headline(lastAttempt: now), .unreadable)
        XCTAssertEqual(issue("error:credentials_missing;failures=1;since=\(justStarted)").headline(lastAttempt: now), .setup)
        // Claude 밖의 auth_expired는 기존 문턱을 따른다
        XCTAssertFalse(issue("auth_expired;failures=1;since=\(justStarted)", provider: "codex").needsActionNow)
        XCTAssertEqual(issue("auth_expired;failures=1;since=\(justStarted)", provider: "codex").headline(lastAttempt: now), .retrying)
        // 문턱을 넘긴 요청 제한은 기존대로 확인 필요
        let longAgo = Int(now.timeIntervalSince1970) - 25 * 60
        XCTAssertEqual(issue("error:rate_limited;failures=5;since=\(longAgo)").headline(lastAttempt: now), .needsAttention)
    }

    /// "다른 PC는 정상" 판정은 ok만 파라미터와 무관하게 받아들인다. shared는 수집하지 않은 기기라 세지 않는다
    /// (임대를 쥔 기기가 끊기지 않았으면 그 기기의 ok가 세어진다). 이 기기 자신, 끊긴 기기, "_" 키만 있는 기기,
    /// 비슷하게 생긴 다른 종류도 세지 않는다.
    func testHealthyPeerCountsOnlyOkWithOrWithoutParameters() {
        let failing = device("mac", status: ["claude": "auth_expired;failures=6;since=1789340000"])
        func hasPeer(_ peer: CollectorDevice) -> Bool {
            failing.hasHealthyPeer(for: "claude", among: [failing, peer], at: now)
        }
        for healthy in ["ok", "ok;failures=0", "ok;x=y"] {
            XCTAssertTrue(hasPeer(device("mini", status: ["claude": healthy])), healthy)
        }
        for unhealthy in ["shared", "shared;failures=0", "shared;retry_at=1789345000;x=y",
                          "error:rate_limited;retry_at=1789345000", "error:rate_limited;deferred=1",
                          "stale", "auth_expired", "auth_expired:revoked", "okay", "shared_elsewhere", ""] {
            XCTAssertFalse(hasPeer(device("mini", status: ["claude": unhealthy])), unhealthy)
        }
        XCTAssertFalse(hasPeer(device("mini", status: ["codex": "ok"])))
        XCTAssertFalse(hasPeer(device("mini", status: ["_collector": "0.2.0"])))
        XCTAssertFalse(hasPeer(device("mini", status: nil)))
        XCTAssertFalse(hasPeer(device("mini", seenAt: now.addingTimeInterval(-3600), status: ["claude": "ok"])), "끊긴 기기")
        let selfHealthy = device("mac", status: ["claude": "ok"])
        XCTAssertFalse(selfHealthy.hasHealthyPeer(for: "claude", among: [selfHealthy], at: now), "자기 자신은 다른 PC가 아니다")
    }

    /// 여러 기기 조합: 실패 중인 기기, 끊긴 기기, shared만 보내는 기기뿐이면 정상인 PC가 없고, ok를 보내는 끊기지 않은
    /// 기기가 하나라도 있으면 있다. 429 게이트에 막힌 임대 보유 기기(D1)의 나머지 기기는 모두 shared를 보내지만
    /// 아무도 수집하지 않으므로, 보유 기기의 복구 카드는 "다른 PC는 정상"이라고 하지 않고 숨기기를 제안해야 한다.
    func testHealthyPeerAmongSeveralDevices() {
        let since = Int(now.timeIntervalSince1970) - 30 * 60
        let retry = Int(now.timeIntervalSince1970) + 600
        let limited = device("mac", status: ["claude": "error:rate_limited;retry_at=\(retry);deferred=1;failures=7;since=\(since)"])
        let expired = device("air", status: ["claude": "auth_expired;failures=6;since=\(since)"])
        let idle = device("mini", status: ["claude": "shared;failures=0"])
        let idle2 = device("studio", status: ["claude": "shared;failures=0"])
        let offlineOK = device("imac", seenAt: now.addingTimeInterval(-3600), status: ["claude": "ok"])
        let holderOK = device("book", status: ["claude": "ok;failures=0"])
        XCTAssertEqual(limited.collectIssues.first?.isPersistent(lastAttempt: now), true, "복구 카드가 뜨는 상태다")
        XCTAssertEqual(expired.collectIssues.first?.isPersistent(lastAttempt: now), true, "복구 카드가 뜨는 상태다")
        // 게이트에 막힌 임대 보유 기기와 shared로 물러난 나머지 기기들: 아무도 수집하지 않는다
        XCTAssertFalse(limited.hasHealthyPeer(for: "claude", among: [limited, idle, idle2], at: now))
        XCTAssertFalse(expired.hasHealthyPeer(for: "claude", among: [expired, limited, offlineOK], at: now))
        XCTAssertFalse(expired.hasHealthyPeer(for: "claude", among: [expired, limited, idle], at: now))
        // 임대를 쥔 기기가 ok를 보내면 그 기기가 정상인 PC다 (shared 기기가 함께 있어도 같다)
        XCTAssertTrue(expired.hasHealthyPeer(for: "claude", among: [expired, idle, holderOK], at: now))
        XCTAssertTrue(limited.hasHealthyPeer(for: "claude", among: [limited, expired, idle, holderOK], at: now))
    }

    /// 복구 카드는 "N회 연속 실패"라고 하지 않는다. 수집기는 요청을 보내지 않은 사이클(deferred=1, 만료 사전 확인)도
    /// 같은 연속으로 세기 때문이다. 지속 시간만 말하고, 내림해서 "적어도"가 참이 되게 한다.
    func testRecoveryDurationIsTheSameWhetherOrNotCyclesWereDeferred() {
        let since = Int(now.timeIntervalSince1970) - 20 * 60
        let retry = Int(now.timeIntervalSince1970) + 600
        let deferred = issue("error:rate_limited;retry_at=\(retry);deferred=1;failures=5;since=\(since)")
        let attempted = issue("error:rate_limited;failures=5;since=\(since)")
        XCTAssertTrue(deferred.isPersistent(lastAttempt: now))
        XCTAssertEqual(deferred.failingDuration(lastAttempt: now), 20 * 60)
        XCTAssertEqual(deferred.failingDuration(lastAttempt: now), attempted.failingDuration(lastAttempt: now))
        // 형식이 이상하거나 순서가 뒤집히면 시간을 지어내지 않는다
        XCTAssertNil(issue("error;failures=5").failingDuration(lastAttempt: now))
        XCTAssertNil(issue("error;failures=5;since=\(since)").failingDuration(lastAttempt: nil))
        XCTAssertNil(issue("error;failures=5;since=\(Int(now.timeIntervalSince1970) + 60)").failingDuration(lastAttempt: now))
        XCTAssertNil(issue("error;failures=5;since=nan").failingDuration(lastAttempt: now))

        var en = Calendar(identifier: .gregorian)
        en.locale = Locale(identifier: "en_US")
        var ko = Calendar(identifier: .gregorian)
        ko.locale = Locale(identifier: "ko_KR")
        typealias Issue = CollectorDevice.CollectIssue
        XCTAssertEqual(Issue.atLeastDurationText(20 * 60, calendar: en), "20 minutes")
        XCTAssertEqual(Issue.atLeastDurationText(20 * 60 + 59, calendar: en), "20 minutes", "내림")
        XCTAssertEqual(Issue.atLeastDurationText(119 * 60 + 59, calendar: en), "119 minutes")
        XCTAssertEqual(Issue.atLeastDurationText(2 * 3600, calendar: en), "2 hours")
        XCTAssertEqual(Issue.atLeastDurationText(47 * 3600 + 59 * 60, calendar: en), "47 hours")
        XCTAssertEqual(Issue.atLeastDurationText(3 * 86400 + 23 * 3600, calendar: en), "3 days")
        XCTAssertEqual(Issue.atLeastDurationText(20 * 60, calendar: ko), "20분")
        XCTAssertEqual(Issue.atLeastDurationText(3 * 86400, calendar: ko), "3일")
    }
}
