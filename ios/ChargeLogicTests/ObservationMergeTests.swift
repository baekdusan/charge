import XCTest
@testable import Charge

/// 기기별 관측을 카드 하나로 접는 규칙. 수집 시각(collected_at)과 업로드 시각(last_reported_at)은
/// 다른 축이고, 섞어서 비교하면 시각을 보내지 않는 구버전 수집기가 언제나 이긴다.
final class ObservationMergeTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func stamp(_ date: Date) -> String { iso.string(from: date) }

    private func device(_ id: String, seenAt: Date, status: [String: String]? = nil) -> CollectorDevice {
        CollectorDevice(id: id, label: "PC-\(id)", lastSeenAt: stamp(seenAt), collectStatus: status)
    }

    private func provider(percent: Double, collectedAt: Date?) -> Provider {
        Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: nil,
            weekly: RateWindow(percent: percent, resetsAt: nil, windowMinutes: 10_080),
            extras: nil,
            status: nil,
            account: "acct-a",
            collectedAt: collectedAt.map(stamp)
        )
    }

    private func row(
        device: String,
        collectedAt: Date?,
        reportedAt: Date,
        percent: Double
    ) -> ChargeAPI.ProviderObservationRow {
        ChargeAPI.ProviderObservationRow(
            deviceId: device,
            providerId: "claude",
            account: "acct-a",
            payload: provider(percent: percent, collectedAt: collectedAt),
            collectedAt: collectedAt.map(stamp),
            lastReportedAt: stamp(reportedAt)
        )
    }

    /// 구버전 수집기(0.1.4 이하)는 collected_at을 보내지 않아 실효 시각이 매 업로드마다
    /// "방금"이 된다. 두 축을 섞어 비교하면 캐시 폴백의 묵은 값이 최신 관측을 밀어내고,
    /// 그 payload에는 수집 시각이 없어 나이 문구와 흐림까지 함께 꺼진다.
    func testFreshStampedObservationBeatsUnstampedUpload() {
        let now = Date()
        let merged = ChargeAPI.mergeProviderObservations(
            [
                row(device: "new", collectedAt: now.addingTimeInterval(-120), reportedAt: now.addingTimeInterval(-120), percent: 30),
                row(device: "old", collectedAt: nil, reportedAt: now, percent: 90)
            ],
            canonical: [],
            devices: [device("new", seenAt: now), device("old", seenAt: now)],
            now: now
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.weekly?.percent, 30)
        XCTAssertNotNil(merged.first?.collectedAt, "수집 시각을 아는 관측을 골랐으면 나이도 말할 수 있어야 한다")
        if case .fresh = merged.first?.freshness(at: now) {} else {
            XCTFail("2분 전 수집은 신선해야 한다")
        }
    }

    /// 스탬프를 가진 후보가 전부 묵었을 때만 시각 미상 관측이 자리를 가져간다.
    /// 서버가 charge_upload에서 쓰는 15분 가드와 같은 경계다.
    func testStaleStampedObservationYieldsToRecentUnstampedUpload() {
        let now = Date()
        let merged = ChargeAPI.mergeProviderObservations(
            [
                row(device: "new", collectedAt: now.addingTimeInterval(-40 * 60), reportedAt: now.addingTimeInterval(-40 * 60), percent: 30),
                row(device: "old", collectedAt: nil, reportedAt: now, percent: 90)
            ],
            canonical: [],
            devices: [device("new", seenAt: now.addingTimeInterval(-40 * 60)), device("old", seenAt: now)],
            now: now
        )

        XCTAssertEqual(merged.first?.weekly?.percent, 90)
    }

    /// 시각 미상 관측만 있을 때, 살아 있는 기기는 나이를 단정하지 않는다.
    /// "방금"이라고 말하면 캐시 폴백을 5분마다 올리는 기기가 가장 신선해 보인다.
    func testLiveUnstampedObservationStaysAgeUnknown() {
        let now = Date()
        let merged = ChargeAPI.mergeProviderObservations(
            [row(device: "old", collectedAt: nil, reportedAt: now.addingTimeInterval(-120), percent: 55)],
            canonical: [],
            devices: [device("old", seenAt: now.addingTimeInterval(-120))],
            now: now
        )

        XCTAssertNil(merged.first?.collectedAt)
        if case .unknown = merged.first?.freshness(at: now) {} else {
            XCTFail("살아 있는 구버전 기기의 나이는 미상으로 남아야 한다")
        }
    }

    /// 반대로 며칠 꺼져 있던 구버전 기기의 스냅샷은 마지막 업로드 시각이 나이의 하한을
    /// 말해준다. 이것까지 버리면 사흘 전 값이 현재 상태처럼 밝게 그려진다.
    func testLongSilentUnstampedObservationReportsAgeFloor() {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let merged = ChargeAPI.mergeProviderObservations(
            [row(device: "old", collectedAt: nil, reportedAt: threeDaysAgo, percent: 95)],
            canonical: [],
            devices: [device("old", seenAt: threeDaysAgo)],
            now: now
        )

        XCTAssertNotNil(merged.first?.collectedAt)
        if case .stale = merged.first?.freshness(at: now) {} else {
            XCTFail("사흘 전 업로드가 마지막이면 낡은 것으로 보여야 한다")
        }
    }

    /// 서버는 아직 리셋 전인 창을 canonical에만 남긴다(keep_session). 같은 업로드에서 나온
    /// 관측 payload에는 이번에 수집된 창만 들어 있으므로, 스탬프가 같을 때 관측을 고르면
    /// 살아 있는 세션 창이 앱과 위젯에서 통째로 사라진다.
    func testCanonicalWinsOnEqualStampToKeepPreservedWindows() {
        let now = Date()
        let stampedAt = now.addingTimeInterval(-60)
        let canonical = Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: RateWindow(percent: 35, resetsAt: iso.string(from: now.addingTimeInterval(3 * 3600)), windowMinutes: 300),
            weekly: RateWindow(percent: 70, resetsAt: nil, windowMinutes: 10_080),
            extras: nil,
            status: nil,
            account: "acct-a",
            collectedAt: iso.string(from: stampedAt)
        )
        // 이번 수집은 주간만 읽어 세션이 비어 있다. 시각은 canonical과 같다.
        let observationOnlyWeekly = ChargeAPI.ProviderObservationRow(
            deviceId: "mac",
            providerId: "claude",
            account: "acct-a",
            payload: provider(percent: 70, collectedAt: stampedAt),
            collectedAt: iso.string(from: stampedAt),
            lastReportedAt: iso.string(from: now)
        )

        let merged = ChargeAPI.mergeProviderObservations(
            [observationOnlyWeekly],
            canonical: [canonical],
            devices: [device("mac", seenAt: now)],
            now: now
        )

        XCTAssertEqual(merged.first?.session?.percent, 35, "서버가 살려둔 세션 창이 사라졌다")
        XCTAssertEqual(merged.first?.weekly?.percent, 70)
    }

    /// 순차 배포 중에는 구버전 수집기만 canonical을 갱신할 수 있다.
    /// 시각을 아는 canonical은 시각 미상 관측을 이긴다.
    func testStampedCanonicalBeatsUnstampedObservation() {
        let now = Date()
        let canonical = provider(percent: 42, collectedAt: now.addingTimeInterval(-60))
        let merged = ChargeAPI.mergeProviderObservations(
            [row(device: "old", collectedAt: nil, reportedAt: now, percent: 90)],
            canonical: [canonical],
            devices: [device("old", seenAt: now)],
            now: now
        )

        XCTAssertEqual(merged.first?.weekly?.percent, 42)
    }
}
