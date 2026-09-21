import Foundation

/// 지역 설정(비그레고리력 등)과 무관하게 안정적인 yyyy-MM-dd 처리
enum ChargeDate {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()

    static func todayString() -> String { day.string(from: Date()) }

    /// 스트릭(잔디) 그리드의 폭 — 표시부(ContentView)와 데모 데이터 생성부가 같은 값을 쓴다
    static let streakWeeks = 10
}

struct DailyUsage: Codable, Identifiable {
    let period: String
    let totalCost: Double
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let models: [ModelBreakdown]

    var id: String { period }

    var date: Date {
        ChargeDate.day.date(from: period) ?? .distantPast
    }

    /// 같은 모델이 여러 에이전트에 걸쳐 나뉜 항목을 모델명 기준으로 합산
    var mergedModels: [ModelBreakdown] {
        var map: [String: ModelBreakdown] = [:]
        for m in models {
            if let e = map[m.modelName] {
                map[m.modelName] = ModelBreakdown(
                    modelName: m.modelName,
                    cost: e.cost + m.cost,
                    inputTokens: (e.inputTokens ?? 0) + (m.inputTokens ?? 0),
                    outputTokens: (e.outputTokens ?? 0) + (m.outputTokens ?? 0),
                    cacheCreationTokens: (e.cacheCreationTokens ?? 0) + (m.cacheCreationTokens ?? 0),
                    cacheReadTokens: (e.cacheReadTokens ?? 0) + (m.cacheReadTokens ?? 0)
                )
            } else {
                map[m.modelName] = m
            }
        }
        return map.values.sorted { $0.cost > $1.cost }
    }
}

struct ModelBreakdown: Codable, Identifiable {
    let modelName: String
    let cost: Double
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?

    var id: String { modelName }

    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0) + (cacheReadTokens ?? 0)
    }
}

/// 모델명으로 프로바이더 추정 (비용을 프로바이더별로 나누기 위함)
func providerId(forModel m: String) -> String {
    let l = m.lowercased()
    if l.contains("claude") { return "claude" }
    if l.hasPrefix("gpt") || l.contains("codex") { return "codex" }
    if l.contains("gemini") { return "gemini" }
    return "other"
}

extension DailyUsage {
    /// 프로바이더 필터 적용 비용 (nil이면 전체)
    func cost(for pid: String?) -> Double {
        guard let pid else { return totalCost }
        return mergedModels.filter { providerId(forModel: $0.modelName) == pid }
            .reduce(0) { $0 + $1.cost }
    }

    /// 프로바이더 필터 적용 토큰 수 (nil이면 전체)
    func tokens(for pid: String?) -> Int {
        guard let pid else { return totalTokens }
        return mergedModels.filter { providerId(forModel: $0.modelName) == pid }
            .reduce(0) { $0 + $1.totalTokens }
    }
}

/// 수집 신선도 판정의 단일 기준, 앱 카드와 위젯이 같은 값을 봐야
/// 같은 데이터가 위젯에선 경고, 앱에선 정상으로 보이는 일이 없다
enum ChargeFreshness {
    /// 표시 중인 스냅샷이 이만큼 묵으면 낡은 것으로 본다 (수집 주기 5분의 네 배)
    static let staleAge: TimeInterval = 20 * 60
    /// 여기를 넘는 나이는 데이터가 아니라 시계가 이상한 것, 나이를 말하지 않는 경계
    static let implausibleAge: TimeInterval = 30 * 86400
    /// 기기 시계가 조금 앞서는 정도는 봐준다
    static let futureSlack: TimeInterval = 60 * 60
    /// 수집 시각을 모르는 관측(구버전 수집기)이 시각을 아는 관측을 밀어낼 수 있는 경계.
    /// 서버가 charge_upload에서 쓰는 15분 가드와 같은 값이어야 한다, 두 쪽이 어긋나면
    /// 서버가 안 받은 값을 앱이 채택하거나 그 반대가 된다.
    static let supersedeAge: TimeInterval = 15 * 60
    /// 가장 긴 창(주간 7일)보다 오래된 카드는 지금 한도에 대해 아무것도 말해주지 못한다.
    /// 같은 프로바이더에 더 신선한 카드가 있으면 이 경계를 넘은 카드는 목록에서 뺀다.
    static let outdatedCardAge: TimeInterval = 7 * 86400
}

/// 스냅샷 하나의 신선도. "흐리게 할까"와 "나이를 말할 수 있나"는 다른 질문이라 함께 답한다.
enum CollectionFreshness {
    /// 임계값 안, 그대로 밝게
    case fresh(Date)
    /// 수집 시각을 알고, 그게 오래됨, 흐리게 + "N분 전 데이터"
    case stale(Date)
    /// 미래, 30일 초과 등 시각 자체를 믿을 수 없음, 나이는 못 말해도 정상인 척 밝게 두면 안 된다
    case untrusted
    /// 수집 시각 미상(구버전 수집기), 판정 유보라서 흐리게 하지 않는다
    case unknown

    /// 게이지, 숫자를 낮춰야 하는가
    var isStale: Bool {
        switch self {
        case .fresh, .unknown: return false
        case .stale, .untrusted: return true
        }
    }

    /// "N분 전 데이터"에 쓸 수 있는 시각, nil이면 나이 대신 "오래된 데이터"라고만 한다
    var ageDate: Date? {
        if case .stale(let d) = self { return d }
        return nil
    }
}

struct Provider: Codable, Identifiable {
    let id: String
    let name: String
    let plan: String?           // 구독 플랜 표시명 (예: "Max 20x", "Education")
    let session: RateWindow?
    let weekly: RateWindow?
    let extras: [ExtraWindow]?
    let status: ProviderStatus?
    var account: String? = nil      // 계정 해시 — 머신마다 계정이 다르면 카드가 분리된다
    var deviceId: String? = nil     // 이 값을 채택한 관측의 기기 id
    var deviceLabel: String? = nil  // 이 계정을 마지막으로 보고한 머신 이름
    var deviceLabels: [String]? = nil // 같은 계정을 현재 관측 중인 모든 머신
    var collectedAt: String? = nil  // 수집기가 실제 소스에서 데이터를 얻은 시각 — 레거시 수집기는 nil
    /// collectedAt이 수집기 스탬프가 아니라 마지막 업로드 시각(나이의 하한)으로 채운 값인가.
    /// 나이 문구와 흐림에는 하한도 쓰지만, "다른 카드보다 더 신선한가"를 가리는 근거는 못 된다. 구버전 캐시는 nil.
    var collectedAtIsUploadFloor: Bool? = nil

    /// 계정까지 포함한 고유 식별자 (같은 프로바이더의 계정별 카드 구분용)
    var uid: String { "\(id)#\(account ?? "")" }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    var collectedDate: Date? {
        guard let collectedAt else { return nil }
        return Self.isoFrac.date(from: collectedAt) ?? Self.iso.date(from: collectedAt)
    }

    /// 이 프로바이더 스냅샷 하나의 신선도.
    /// 수집은 프로바이더마다 따로 깨진다(한쪽은 정상, 한쪽은 캐시 폴백), 그래서 판정도 반드시
    /// 프로바이더별이다. 여러 프로바이더의 최댓값으로 판정하면 옆에서 정상 수집되는 동안
    /// 몇 시간 묵은 값이 아무 표시 없이 밝게 그려진다.
    func freshness(at now: Date = Date()) -> CollectionFreshness {
        guard let d = collectedDate else { return .unknown }
        let age = now.timeIntervalSince(d)
        // 미래거나 비상식적으로 낡은 값(시계가 어긋난 기기), 나이는 말할 수 없어도
        // 신선한 것으로 넘기면 "가장 낡은 데이터가 가장 멀쩡해 보이는" 뒤집힌 결과가 된다
        guard age >= -ChargeFreshness.futureSlack, age <= ChargeFreshness.implausibleAge else {
            return .untrusted
        }
        return age > ChargeFreshness.staleAge ? .stale(d) : .fresh(d)
    }

    /// 수집기가 실제로 찍은 수집 시각. 업로드 시각 하한으로 채운 값은 nil이다.
    var stampedDate: Date? {
        collectedAtIsUploadFloor == true ? nil : collectedDate
    }

    /// 이 카드가 지금 한도에 대해 아무것도 말해주지 못하게 되는 나이. 기본은 가장 긴 표준 창(주간 7일)이고,
    /// 더 긴 창(예: 월간)을 가진 카드는 그 창 길이까지 기다린다. 창 길이보다 먼저 빼면 아직 유효한 한도가 사라진다.
    var outdatedCardAge: TimeInterval {
        let windows = [session, weekly] + (extras ?? []).map { Optional($0.window) }
        let longestMinutes = windows.compactMap { $0?.windowMinutes }.filter { $0 > 0 }.max() ?? 0
        return max(ChargeFreshness.outdatedCardAge, TimeInterval(longestMinutes) * 60)
    }

    /// "Dusanui-MacBookPro.local" → "Dusanui-MacBookPro"
    var deviceShortLabel: String? {
        guard let l = deviceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else { return nil }
        return l.hasSuffix(".local") ? String(l.dropLast(6)) : l
    }

    /// 원문 식별자는 업로드하지 않으므로 사용자가 계정을 구분할 최소한의 안정적인 표시명.
    /// unknown 접두사는 프로필 조회 실패로 기기별 격리된 관측임을 뜻한다.
    var accountShortLabel: String? {
        guard let account, !account.isEmpty else { return nil }
        if account.hasPrefix("unknown:") { return String(localized: "Unidentified account") }
        return String(localized: "Account") + " " + account.suffix(4).uppercased()
    }

    var accountContextLabel: String? {
        let observed = (deviceLabels ?? [deviceShortLabel].compactMap { $0 })
        let deviceContext: String?
        if observed.count > 2 {
            deviceContext = "\(observed[0]) +\(observed.count - 1)"
        } else {
            deviceContext = observed.joined(separator: ", ").nilIfEmpty
        }
        return [deviceContext, accountShortLabel].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Array where Element == Provider {
    /// 오래된 카드 정리. 표시 단계 전용이다(앱 카드, 위젯, 리셋 알림). 스트릭 보호의 계정 목록처럼
    /// "그 계정이 존재하는가"를 묻는 곳은 걸러지지 않은 목록을 봐야 한다. 거기서 빼면 막혀 있던 계정이
    /// 목록에서 사라져 보호일 판정이 달라진다.
    ///
    /// 은퇴 규칙은 수집이 실패 중인 기기의 마지막 관측을 일부러 보존한다. 그래서 그 기기가 몇 주째 실패하면
    /// 한 달 묵은 "확인되지 않은 계정" 카드가 영영 남는다. 가장 긴 창(outdatedCardAge)보다 오래된 카드는
    /// 같은 프로바이더에 수집 시각이 확실히 더 늦은 카드가 있을 때만 뺀다. 그 프로바이더의 유일한 카드라면
    /// 그대로 두고 "오래된 데이터" 문구에 맡긴다(사라지면 멀쩡하다고 읽힌다).
    /// 수집 시각 미상인 카드(업로드 시각만 아는 카드 포함)와 시계가 크게 앞선 미래 시각은 더 신선하다고
    /// 단정할 근거가 없으므로 남의 카드를 밀어내지 않는다. 같은 시각도 "더 신선"이 아니다.
    func hidingOutdatedCards(at now: Date = Date()) -> [Provider] {
        let trustedUntil = now.addingTimeInterval(ChargeFreshness.futureSlack)
        let stamps = map(\.stampedDate)
        return enumerated().filter { index, card in
            guard let at = card.collectedDate,
                  now.timeIntervalSince(at) > card.outdatedCardAge else { return true }
            return !indices.contains { other in
                other != index
                    && self[other].id == card.id
                    && (stamps[other].map { $0 > at && $0 <= trustedUntil } ?? false)
            }
        }.map(\.element)
    }
}

struct ProviderStatus: Codable {
    let indicator: String       // none | minor | major | critical
    let description: String?

    var isHealthy: Bool { indicator == "none" }
}

struct ExtraWindow: Codable, Identifiable {
    let name: String
    let window: RateWindow
    var id: String { name }
}

struct RateWindow: Codable {
    let percent: Double
    let resetsAt: String?
    let windowMinutes: Int?
    let label: String?

    init(percent: Double, resetsAt: String?, windowMinutes: Int? = nil, label: String? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.label = label
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    var resetDate: Date? {
        guard let s = resetsAt else { return nil }
        return Self.isoFrac.date(from: s) ?? Self.iso.date(from: s)
    }

    /// 리셋 시각이 이미 지난 창 (수집 지연으로 생기는 낡은 스냅샷)
    var isStale: Bool {
        guard let d = resetDate else { return false }
        return d < Date()
    }

    /// 마지막으로 알려진 리셋이 지난 경우, 다음 창을 0% 추정값으로 표시한다.
    /// 실제 수집값이 도착하면 이 상태는 즉시 교체된다.
    func displayState(at now: Date = Date()) -> RateWindowDisplayState? {
        guard let end = resetDate, end <= now else {
            return RateWindowDisplayState(window: self, isEstimated: false)
        }
        guard let mins = windowMinutes, mins > 0 else { return nil }

        let duration = Double(mins) * 60
        let completedWindows = floor(max(0, now.timeIntervalSince(end)) / duration) + 1
        let nextReset = end.addingTimeInterval(completedWindows * duration)
        let inferred = RateWindow(
            percent: 0,
            resetsAt: Self.isoFrac.string(from: nextReset),
            windowMinutes: mins,
            label: label
        )
        return RateWindowDisplayState(window: inferred, isEstimated: true)
    }

    /// 스냅샷 신선도까지 반영한 표시 상태. 묵은 스냅샷인데 리셋 시각도 없는 창은
    /// 그 사이 창이 시작됐는지, 리셋됐는지조차 알 수 없어 값을 모르는 것으로 본다.
    /// (수집기 캐시가 리셋 시각 없는 창을 계속 재생하면 한 달 전 0%가 "지금 0%"로 그려졌다)
    func displayState(at now: Date = Date(), stale: Bool) -> RateWindowDisplayState? {
        guard var state = displayState(at: now) else { return nil }
        state.isUnknown = stale && resetDate == nil
        state.isStale = stale
        return state
    }

    /// "Resets in 4h 9m" 형태의 남은 시간 문자열
    var resetText: String? {
        guard let d = resetDate else { return nil }
        guard d.timeIntervalSinceNow > 0 else { return String(localized: "Resets soon") }
        return String(localized: "Resets in \(resetShort ?? "")")
    }

    /// 위젯용 축약 표기: "4h 9m", "5d 6h"
    var resetShort: String? {
        guard let d = resetDate else { return nil }
        let sec = Int(d.timeIntervalSinceNow)
        guard sec > 0 else { return String(localized: "soon") }
        let day = sec / 86400, h = (sec % 86400) / 3600, m = (sec % 3600) / 60
        if day > 0 { return "\(day)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// 창 경과율 0...1 — 시간 진행 막대용. 창 길이를 모르면 nil.
    var timeProgress: Double? {
        guard let mins = windowMinutes, mins > 0, let end = resetDate else { return nil }
        let duration = Double(mins) * 60
        return min(1, max(0, 1 - end.timeIntervalSinceNow / duration))
    }

    /// 페이스 배율: 사용률 ÷ 창 경과율. 1보다 크면 리셋 전 한도 소진 페이스.
    var pace: Double? {
        guard let mins = windowMinutes, mins > 0, let end = resetDate else { return nil }
        let duration = Double(mins) * 60
        let elapsed = duration - end.timeIntervalSinceNow
        guard elapsed > duration * 0.02 else { return nil }  // 창 초반에는 노이즈라 생략
        let elapsedPct = min(elapsed / duration, 1) * 100
        return percent / elapsedPct
    }

    /// 이 페이스로 한도(100%)에 도달하는 시각. 리셋 이후면 nil (= 안전).
    var projectedExhaustion: Date? {
        guard let p = pace, p > 0, percent < 100, let mins = windowMinutes, let end = resetDate else {
            return percent >= 100 ? Date() : nil
        }
        let duration = Double(mins) * 60
        let elapsed = duration - end.timeIntervalSinceNow
        let secondsTo100 = elapsed * (100 / percent) - elapsed
        let eta = Date().addingTimeInterval(secondsTo100)
        return eta < end ? eta : nil
    }
}

struct RateWindowDisplayState {
    let window: RateWindow
    let isEstimated: Bool
    /// 값을 모르는 창(묵은 스냅샷 + 리셋 시각 없음). 숫자를 그리는 순간 "안 썼다"는 단언이 되므로
    /// 퍼센트 대신 "최근 데이터 없음"으로 그린다. 앱 카드와 위젯이 같은 판정을 쓴다.
    var isUnknown = false
    /// 이 창이 속한 스냅샷이 묵었다(displayState(at:stale:)가 채운다)
    var isStale = false

    /// "이 속도면 소진" 줄에 쓸 예측 시각. 값 미상, 추정값, 한도 도달("한도 도달"로 따로 그린다),
    /// 묵은 스냅샷에서는 nil이다. 페이스는 지금 시각의 창 경과율로 계산하는데 사용률은 수집 시점 값이라,
    /// 묵은 스냅샷이면 실제보다 느린 예측이 흐린 숫자 옆에서 현재 경고처럼 밝게 그려진다.
    var paceWarning: Date? {
        guard !isUnknown, !isEstimated, !isStale, window.percent < 100 else { return nil }
        return window.projectedExhaustion
    }
}

/// 지금 실제 사용을 막고 있는 한도 한 건. session/weekly는 계정 전체,
/// extras는 특정 모델 범위라 UI 문구와 스트릭 판정에서 반드시 구분한다.
struct ProviderLimitState {
    let title: String
    let window: RateWindow
    let isProviderWide: Bool

    var resetDate: Date? { window.resetDate }
}

extension Provider {
    private func activeLimit(
        title: String,
        window: RateWindow,
        providerWide: Bool,
        at now: Date
    ) -> ProviderLimitState? {
        guard window.percent >= 100 else { return nil }
        if let reset = window.resetDate, reset <= now { return nil }
        // 게이지가 값을 모른다고 그리는 창(묵은 스냅샷 + 리셋 시각 없음)을 배너만 "한도 도달"로
        // 단언하면 같은 카드가 두 말을 한다. 표시 규칙(displayState(of:))과 같은 판정을 쓴다.
        if window.resetDate == nil, freshness(at: now).isStale { return nil }
        return ProviderLimitState(title: title, window: window, isProviderWide: providerWide)
    }

    /// 이 프로바이더 스냅샷의 신선도를 반영한 창 표시 상태. 앱 카드와 위젯은 창을 그릴 때 이것만 쓴다.
    func displayState(of window: RateWindow, at now: Date = Date()) -> RateWindowDisplayState? {
        window.displayState(at: now, stale: freshness(at: now).isStale)
    }

    /// 여러 계정 전체 창이 동시에 막혔으면 가장 늦게 풀리는 창이 실제 재사용 시각을 결정한다.
    /// reset_at이 없는 100%는 언제 풀릴지조차 모르므로 알려진 시각보다 더 강한 차단으로 본다.
    private func strictest(_ limits: [ProviderLimitState]) -> ProviderLimitState? {
        if let unknown = limits.first(where: { $0.resetDate == nil }) { return unknown }
        return limits.max { ($0.resetDate ?? .distantPast) < ($1.resetDate ?? .distantPast) }
    }

    func providerWideLimit(at now: Date = Date()) -> ProviderLimitState? {
        var limits: [ProviderLimitState] = []
        if let session, let limit = activeLimit(
            title: session.label ?? String(localized: "Session"),
            window: session,
            providerWide: true,
            at: now
        ) { limits.append(limit) }
        if let weekly, let limit = activeLimit(
            title: weekly.label ?? String(localized: "Weekly"),
            window: weekly,
            providerWide: true,
            at: now
        ) { limits.append(limit) }
        return strictest(limits)
    }

    /// 모델별 제한은 전체 프로바이더를 사용할 수 없다고 말하지 않는다.
    func scopedLimit(at now: Date = Date()) -> ProviderLimitState? {
        strictest((extras ?? []).compactMap { extra in
            activeLimit(
                title: extra.window.label ?? extra.name,
                window: extra.window,
                providerWide: false,
                at: now
            )
        })
    }

    func activeLimit(at now: Date = Date()) -> ProviderLimitState? {
        providerWideLimit(at: now) ?? scopedLimit(at: now)
    }

    /// 대표 창 하나만 그리는 화면(잠금화면 위젯, 인라인)이 고를 창.
    /// 계정 전체가 막혀 있으면 그 창, 아니면 세션, 세션 창이 없으면 주간이다.
    /// 단, 묵은 스냅샷에서 값을 모르는 세션(쉬는 중이라 리셋 시각 없음)보다는 값을 아는 주간이 대표다.
    /// 요청 제한 대기로 스냅샷이 20분을 넘기는 일이 흔한데, 그때 세션을 고르면 앱 카드는 주간 값을
    /// 그리는데 잠금화면만 자리표시자가 되고, 대표 프로바이더 순위에서도 가장 낮게 밀린다.
    /// 카드와 홈 위젯이 그리는 모집단(세션 또는 주간)과 반드시 같아야, 같은 데이터가
    /// 한쪽에서만 "No data"로 사라지지 않는다. 그래서 위젯이 아니라 여기 공유 모델에 둔다.
    func primaryDisplayWindow(at now: Date = Date()) -> ProviderPrimaryWindow? {
        if let limit = providerWideLimit(at: now) {
            return ProviderPrimaryWindow(id: "blocking", title: limit.title, window: limit.window)
        }
        // 값 미상 판정은 창을 고를 때만 쓴다. 고를 수 있는 창이 있는지(모집단)는 예전과 같다.
        let sessionState = session.flatMap { displayState(of: $0, at: now) }
        let weeklyState = weekly.flatMap { displayState(of: $0, at: now) }
        let weeklyIsKnown = weeklyState.map { !$0.isUnknown } ?? false
        if let session, let sessionState, !(sessionState.isUnknown && weeklyIsKnown) {
            return ProviderPrimaryWindow(
                id: "session",
                title: session.label ?? String(localized: "Session"),
                window: session
            )
        }
        if let weekly, weeklyState != nil {
            return ProviderPrimaryWindow(
                id: "weekly",
                title: weekly.label ?? String(localized: "Weekly"),
                window: weekly
            )
        }
        return nil
    }
}

/// 대표 창 하나를 가리키는 값. 위젯의 줄 모델과 같은 모양이라 그대로 옮겨 담는다.
struct ProviderPrimaryWindow {
    let id: String
    let title: String
    let window: RateWindow
}

/// 서버가 최소한으로 보존한 Claude 7일 한도 소진 구간. 최신 Provider 스냅샷은
/// 리셋 뒤 0%로 바뀌지만 이 행은 남아, 여러 기기에서 같은 스트릭 보호일을 계산할 수 있다.
struct QuotaBlock: Codable, Identifiable {
    let providerId: String
    let account: String
    let windowKind: String
    let resetAt: String
    /// 이 차단을 관측할 때 알려져 있던 같은 프로바이더 계정들. 이후 연결 해제되어도
    /// 과거의 사용 가능 계정이 사라진 것처럼 계산하지 않는다. 구버전 캐시는 nil.
    var observedAccounts: [String]? = nil
    let firstSeenAt: String
    let lastSeenAt: String
    let clearedAt: String?

    /// 한 리셋 창에 구간이 여러 개일 수 있어(막힘, 해제, 재차단) 시작 시각까지 넣어야 유일하다.
    var id: String { "\(providerId)#\(account)#\(windowKind)#\(resetAt)#\(firstSeenAt)" }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFrac.date(from: value) ?? iso.date(from: value)
    }

    var firstSeenDate: Date? { Self.date(firstSeenAt) }
    var resetDate: Date? { Self.date(resetAt) }
    var clearedDate: Date? { Self.date(clearedAt) }

    /// 5분 수집 주기에서 일시적인 절전/네트워크 지연이 세 번 겹쳐도 놓치지 않도록
    /// 자정 뒤 30분 이내의 첫 관측을 허용한다.
    /// 시작과 끝을 모두 덮는 날만 보호해, 오후에 한도를 쓴 날을 공짜 보호일로 만들지 않는다.
    func protects(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard let first = firstSeenDate, let reset = resetDate,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else {
            return false
        }
        let start = calendar.startOfDay(for: day)
        let effectiveEnd = min(reset, clearedDate ?? reset)
        return first <= start.addingTimeInterval(30 * 60)
            && effectiveEnd >= nextDay.addingTimeInterval(-60)
    }

    /// 이 구간이 그날과 조금이라도 겹치는가. "그날 함께 쓰이던 계정"을 모으는 용도라
    /// 하루를 다 덮었는지는 따지지 않는다. 반나절만 막힌 계정도 증거로 남아야 한다.
    func overlaps(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard let first = firstSeenDate, let reset = resetDate,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else {
            return false
        }
        let start = calendar.startOfDay(for: day)
        let effectiveEnd = min(reset, clearedDate ?? reset)
        return first < nextDay && effectiveEnd > start
    }
}

enum StreakProtection {
    /// 선택한 프로바이더의 현재 계정이 모두 하루 전체 차단됐을 때만 보호한다.
    /// 한 계정의 이력이 없다는 이유로 다른 계정의 차단을 대신 적용하지 않는다.
    static func protectedPeriods(
        providerId: String?,
        accounts: Set<String>,
        blocks: [QuotaBlock],
        now: Date = Date(),
        historyDays: Int = 120,
        calendar: Calendar = .current
    ) -> Set<String> {
        guard let providerId, !accounts.isEmpty else { return [] }
        // 계정으로 여기서 거르면 아래 완결성 검사(현재 계정 + 그때 함께 관측된 계정)와 기준이
        // 어긋나 만족할 수 없는 조건이 된다. 두 계정이 모두 막혔던 날에 그중 하나를 나중에
        // 연결 해제하면 그날 보호가 소급 취소되던 이유다. 여기서는 프로바이더로만 좁히고
        // 계정 판정은 검사 한 곳에서만 한다.
        let relevant = blocks.filter { $0.providerId == providerId }
        guard !relevant.isEmpty else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 비교 대상 키(ChargeDate.day가 만드는 period 문자열)는 그레고리력이다. 주입된 달력을
        // 그대로 쓰면 불교력 같은 지역에서 "2568-08-16"이 나와 어떤 키와도 만나지 못하고
        // 보호가 조용히 사라진다. 달력은 고정하고 시간대만 주입된 값을 따른다.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone

        var result = Set<String>()
        for back in 0..<max(0, historyDays) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let covering = relevant.filter { $0.protects(day, calendar: calendar) }
            // 그날 함께 쓰이던 계정 집합은 하루를 다 덮은 구간이 아니라 그날과 조금이라도
            // 겹친 모든 구간에서 모은다. 덮은 구간만 보면, 정오부터만 막혔던 계정은 증거가
            // 빠져 기대 집합에서 사라지고 그 계정이 연결 해제된 뒤에는 실제로 쓸 수 있었던
            // 날까지 보호된다.
            let historicallyObserved = relevant
                .filter { $0.overlaps(day, calendar: calendar) }
                .reduce(into: Set<String>()) { known, block in
                    known.formUnion(block.observedAccounts ?? [])
                }
            // 판정 기준은 "그날 알려져 있던 계정"이지 "지금 연결된 계정"이 아니다. 현재 계정을
            // 합치면, 그날 존재하지도 않던 계정을 나중에 연결하는 순간 과거 보호일이 소급해서
            // 사라진다(그 구간의 observedAccounts는 리셋이 지나 다시 갱신되지 않는다).
            // 서버는 차단 여부와 무관하게 그때 알려진 계정 전부를 구간에 적어두므로 이것으로 충분하다.
            // observedAccounts가 없는 구버전 행에서만 현재 계정 집합으로 폴백한다.
            let expectedAccounts = historicallyObserved.isEmpty ? accounts : historicallyObserved
            let everyAccountBlocked = !expectedAccounts.isEmpty && expectedAccounts.allSatisfy { account in
                covering.contains { $0.account == account }
            }
            if everyAccountBlocked { result.insert(formatter.string(from: day)) }
        }
        return result
    }
}

struct CollectorDevice: Codable, Identifiable {
    let id: String
    let label: String?
    let lastSeenAt: String?
    /// 프로바이더 id → 수집 상태 ("ok" | "shared" | "auth_expired" | "stale" | "error"), 레거시 수집기는 nil.
    /// "_"로 시작하는 키는 프로바이더가 아니라 수집기 메타데이터다(예: "_collector"), providerStatuses로 읽는다.
    var collectStatus: [String: String]? = nil
    /// charge_devices.collector_version. 컬럼이 없는 서버, 구버전 캐시에서는 nil
    var collectorVersion: String? = nil

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    var lastSeenDate: Date? {
        guard let lastSeenAt else { return nil }
        return Self.isoFrac.date(from: lastSeenAt) ?? Self.iso.date(from: lastSeenAt)
    }

    /// "Dusanui-MacBookPro.local" → "Dusanui-MacBookPro"
    var shortLabel: String? {
        guard let l = label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else { return nil }
        return l.hasSuffix(".local") ? String(l.dropLast(6)) : l
    }

    /// 수집기는 5분 주기로 업로드한다 — 마지막 업로드가 12분 이내면 추적 중으로 본다
    /// (시계 오차 대비 미래 1분까지 허용)
    func isTracking(at now: Date) -> Bool {
        guard let seen = lastSeenDate else { return false }
        let age = now.timeIntervalSince(seen)
        return age >= -60 && age <= 12 * 60
    }

    /// 수집 상태 키 자체를 안 보내는 기기(구버전 수집기), 업로드는 오고 있으니 "추적 중"이지만
    /// "이상 없음"은 아니다. 이때만 업데이트 안내가 통한다.
    var isLegacyCollector: Bool { collectStatus == nil }

    /// 프로바이더 상태만 남긴 맵. "_"로 시작하는 키(수집기 버전 등)는 경고, 설정 목록, 은퇴 판정
    /// 어디에도 프로바이더로 섞이면 안 된다. 상태 맵 자체가 없는 구버전 수집기는 nil.
    var providerStatuses: [String: String]? {
        collectStatus?.filter { !$0.key.hasPrefix("_") }
    }

    func status(for providerId: String) -> CollectStatus? {
        providerStatuses?[providerId].map(CollectStatus.init)
    }

    /// 최신 수집기인데 볼 프로바이더를 하나도 못 찾은 기기(자격증명이 없는 PC)는 빈 맵을 올린다.
    /// 구버전과 같이 묶어 "업데이트하세요"라고 하면 해봐야 아무것도 안 바뀌는 안내가 된다.
    var hasNoProviders: Bool { providerStatuses?.isEmpty == true }

    /// 이 기기 수집기의 버전. 서버 컬럼이 우선이고, 컬럼을 모르는 서버가 상태 맵에 그대로 저장한
    /// "_collector" 키로 폴백한다.
    var reportedCollectorVersion: String? {
        [collectorVersion, collectStatus?["_collector"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 업로드는 오고 있는데(추적 중) 자동 업데이트가 없는 수집기(0.2.0 미만, 또는 버전 미상).
    /// 이런 설치는 스스로 고쳐지지 않으므로 사용자가 한 번 업데이트 명령을 실행해야 한다.
    func needsCollectorUpdate(at now: Date) -> Bool {
        guard isTracking(at: now) else { return false }
        guard let version = reportedCollectorVersion.flatMap(CollectorVersion.init) else { return true }
        return version < CollectorVersion.selfUpdating
    }

    /// 수집 실패 프로바이더 한 건 — 안내 문구에 쓸 표시 이름과 상태
    struct CollectIssue: Identifiable {
        let providerId: String
        let providerName: String
        let status: String
        /// 이 기기 수집기가 만료와 폐기(auth_expired:revoked)를 나눠 보내는가(0.2.0 이상).
        /// 모르면 false, 구버전은 401을 전부 "auth_expired"로 보냈으므로 만료라고 단언하지 않는다.
        var distinguishesRevoked = false
        var id: String { providerId }
        var parsed: CollectStatus { CollectStatus(status) }
        var isAuthExpired: Bool { parsed.isAuthExpired }
        var isRevoked: Bool { parsed.isRevoked }
        var isRateLimited: Bool { parsed.isRateLimited }
        var isAccessDenied: Bool { parsed.isAccessDenied }
        var needsSetup: Bool { parsed.needsSetup }
        var isSignedOut: Bool { parsed.isSignedOut }

        var consecutiveFailures: Int? { parsed.consecutiveFailures }

        /// 연속 실패의 첫 사이클(since)부터 마지막 보고까지의 시간. 형식이 이상하거나 모르면 nil.
        /// Use the last collector report, not wall-clock time: leaving the app
        /// open must not turn five quick retries into twenty minutes of failures.
        func failingDuration(lastAttempt: Date?) -> TimeInterval? {
            guard let raw = parsed.parameter("since"), let seconds = TimeInterval(raw), seconds.isFinite,
                  seconds > 0, let lastAttempt else { return nil }
            let duration = lastAttempt.timeIntervalSince1970 - seconds
            return duration > 0 ? duration : nil
        }

        func isPersistent(lastAttempt: Date?) -> Bool {
            guard let count = consecutiveFailures, count >= 5,
                  let duration = failingDuration(lastAttempt: lastAttempt) else { return false }
            return duration >= 20 * 60
        }

        /// 복구 카드의 지속 시간 표기("20분", "5시간", "3일"). 수집기는 요청을 보내지 않은 사이클(만료 사전 확인,
        /// 요청 제한 대기 ";deferred=1", 다른 종류의 오류와 이어진 연속)도 같은 연속 실패로 센다. 그래서 "N회 연속
        /// 시도 실패"라고 하면 보내지도 않은 요청을 실패로 세게 된다. 횟수 대신 시간만 말하고, "적어도"가 거짓이
        /// 되지 않게 단위를 하나만 골라 내림한다.
        static func atLeastDurationText(_ duration: TimeInterval, calendar: Calendar = .current) -> String {
            let minutes = Int(max(0, duration) / 60)
            let formatter = DateComponentsFormatter()
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 1
            let components: DateComponents
            if minutes < 120 {
                formatter.allowedUnits = [.minute]
                components = DateComponents(minute: minutes)
            } else if minutes < 48 * 60 {
                formatter.allowedUnits = [.hour]
                components = DateComponents(hour: minutes / 60)
            } else {
                formatter.allowedUnits = [.day]
                components = DateComponents(day: minutes / 1440)
            }
            return formatter.string(from: components) ?? "\(minutes)"
        }

        /// 기기 상태 줄의 제목
        enum Headline: Equatable {
            /// 자격증명을 못 읽음, 설정 안내
            case setup
            /// 사용자가 무언가 해야 한다
            case needsAttention
            /// 수집기가 알아서 다시 시도하는 중
            case retrying
            /// 실패 횟수를 모르는 구버전 수집기
            case unreadable
        }

        /// 확인된 Claude 로그인 문제(만료, 폐기)는 기다려도 저절로 낫지 않고 할 일도 정해져 있다.
        /// 그래서 5회, 20분 문턱을 기다리지 않고 바로 알린다. 요청 제한과 그 밖의 오류는 문턱을 그대로 둔다.
        var needsActionNow: Bool { isClaude && parsed.isAuthExpired }

        func headline(lastAttempt: Date?) -> Headline {
            if needsSetup { return .setup }
            if needsActionNow || isPersistent(lastAttempt: lastAttempt) { return .needsAttention }
            if consecutiveFailures != nil { return .retrying }
            return .unreadable
        }

        /// 만료(auth_expired)와 폐기(auth_expired:revoked)는 조치가 다르다. 만료는 Claude Code를
        /// 한 번 열면 토큰이 스스로 갱신되는데 "다시 로그인하세요"라고 하면 필요 없는 일을 시킨다.
        /// 이 상태를 보내는 것은 Claude 수집뿐이라, 다른 프로바이더는 기존 일반 문구를 쓴다.
        private var isClaude: Bool { providerId == "claude" }

        func guidance(at now: Date = Date()) -> String {
            let state = parsed
            if state.needsSetup {
                // 끝난 로그인(credentials_missing:signed_out)은 수집기가 Claude Code가 토큰만 비운 껍데기를 확인한
                // 것이라 API 키 계정일 수 없다. /status 확인 대신 /login을 바로 안내한다.
                if state.isSignedOut, isClaude {
                    return String(localized: "Claude Code's sign-in on this PC has ended. Run /login in Claude Code on this PC to sign in again.")
                }
                return String(localized: "Charge found Claude Code but couldn't read its subscription sign-in. Open Claude Code on this PC and check /status. API-key accounts don't provide subscription limits.")
            }
            if state.isRateLimited {
                let base = String(localized: "The usage service is limiting requests. Charge will retry automatically. This does not mean your subscription has ended.")
                guard let retry = state.pendingRetry(at: now) else { return base }
                let time = CollectStatus.retryTimeText(retry, now: now)
                return base + " " + String(localized: "Charge will try again around \(time).")
            }
            if state.isAuthExpired, isClaude {
                if state.isRevoked {
                    return String(localized: "Claude Code's sign-in on this PC is no longer valid. Run /login in Claude Code on this PC to sign in again.")
                }
                // 구버전 수집기의 auth_expired에는 폐기된 로그인도 섞여 있다. "다시 로그인하지 않아도 된다"고
                // 단언하지 않고, 먼저 열어 보되 로그인을 요구하면 /login 하라고 안내한다.
                return distinguishesRevoked
                    ? String(localized: "Claude Code's sign-in on this PC has expired. Open Claude Code on this PC once and it refreshes automatically. You don't need to sign in again.")
                    : String(localized: "Charge couldn't use Claude Code's sign-in on this PC. Opening Claude Code on this PC once usually refreshes it. If Claude Code asks you to sign in, run /login.")
            }
            if state.isAuthExpired || state.isAccessDenied {
                return String(localized: "Check your sign-in and subscription on this PC. Access may have changed, but Charge can't confirm whether your subscription ended.")
            }
            return String(localized: "The usage service may be temporarily unavailable. Check your connection and try again later. Charge will keep retrying.")
        }

        /// 기기 상태 줄 아래에 붙이는 짧은 조치 한 줄. 할 수 있는 일이 없으면 nil.
        func actionHint(at now: Date = Date()) -> String? {
            let state = parsed
            if state.isSignedOut, isClaude { return String(localized: "Sign in again in Claude Code (/login)") }
            if state.isAuthExpired {
                guard isClaude else { return String(localized: "Try signing in again in \(providerName)") }
                if state.isRevoked { return String(localized: "Sign in again in Claude Code (/login)") }
                return distinguishesRevoked
                    ? String(localized: "Open Claude Code on this PC once")
                    : String(localized: "Open Claude Code on this PC once (run /login if asked)")
            }
            if state.isRateLimited, let retry = state.pendingRetry(at: now) {
                return String(localized: "Next try around \(CollectStatus.retryTimeText(retry, now: now))")
            }
            return nil
        }
    }

    /// 경고로 보여줄 항목만 추린다 — "auth_expired"/"error"류(접두 매칭)만 경고.
    /// "ok", "shared", "stale"은 물론 미래에 추가될 모르는 상태값도 경고로 치지 않는다 (구버전 앱 오경보 방지)
    var collectIssues: [CollectIssue] {
        // 만료라고 단언할 수 있는지는 기기(수집기 버전) 단위라 한 번만 계산한다
        let distinguishesRevoked = reportedCollectorVersion
            .flatMap(CollectorVersion.init)
            .map { $0 >= CollectorVersion.reportsRevokedLogin } ?? false
        return (providerStatuses ?? [:])
            .filter { CollectStatus($0.value).isIssue }
            .sorted { $0.key < $1.key }
            .map { pid, status in
                CollectIssue(
                    providerId: pid,
                    providerName: ChargeConfig.knownProviders[pid] ?? pid.capitalized,
                    status: status,
                    distinguishesRevoked: distinguishesRevoked
                )
            }
    }

    func visibleCollectIssues(hidden: Set<String>) -> [CollectIssue] {
        collectIssues.filter { !hidden.contains($0.providerId) }
    }

    /// 복구 카드의 "다른 PC는 정상" 판정. 다른 기기가 그 프로바이더를 ok로 보고할 때만 정상으로 친다.
    /// ";failures=0" 같은 파라미터가 붙어도 종류로만 판정한다. 업로드가 끊긴 기기와 이 기기 자신은 세지 않는다.
    /// shared는 세지 않는다(D6 문구에서 벗어난 결정): shared는 "누군가 임대를 쥐고 있다"는 뜻일 뿐 그 기기가 수집한 것이
    /// 아니다. 임대를 쥔 기기가 끊기지 않았으면 그 기기의 ok가 따로 세어진다. 429 게이트에 막힌 임대 보유 기기는 임대를
    /// 계속 갱신하므로(D1) 같은 사용자의 나머지 기기는 모두 shared를 보내는데, 이때 shared를 정상으로 치면 아무도 수집하지
    /// 않는데도 보유 기기의 복구 카드가 "다른 PC는 정상"이라고 말하게 된다.
    func hasHealthyPeer(for providerId: String, among devices: [CollectorDevice], at now: Date) -> Bool {
        devices.contains {
            $0.id != id && $0.isTracking(at: now) && $0.status(for: providerId)?.isOK == true
        }
    }
}

/// 수집기가 올리는 프로바이더별 수집 상태 한 건, "종류;키=값;키=값" 모양이다.
/// 구버전 앱은 접두사만 보므로 종류(첫 ";" 앞)의 접두사 호환은 지키고, 뒤의 파라미터는
/// 순서에 기대지 않고 읽는다. 모르는 키, 형식이 깨진 조각은 조용히 무시한다.
struct CollectStatus: Equatable {
    /// 첫 ";" 앞, 예: "ok", "shared", "auth_expired:revoked", "error:rate_limited"
    let kind: String
    let parameters: [String: String]

    init(_ raw: String) {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        kind = (parts.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            // 같은 키가 두 번 오면 먼저 온 값을 쓴다(수집기는 원래 파라미터를 앞에 둔다)
            guard !key.isEmpty, !value.isEmpty, parameters[key] == nil else { continue }
            parameters[key] = value
        }
        self.parameters = parameters
    }

    func parameter(_ key: String) -> String? { parameters[key] }

    var isOK: Bool { kind == "ok" }
    /// 같은 Charge 사용자의 다른 기기가 이번 주기의 조회 임대를 쥐고 있어 이 기기는 요청을 건너뛰었다.
    /// 문제가 아니다: 경고에도, 이 기기의 옛 관측 은퇴 판정에도 ok와 같게 친다. 다만 이 기기가 수집한 것은 아니라서
    /// 복구 카드의 "다른 PC는 정상" 판정(hasHealthyPeer)에는 세지 않는다.
    var isShared: Bool { kind == "shared" }
    /// ok 또는 shared (파라미터 무관)
    var isHealthy: Bool { isOK || isShared }
    /// 경고 대상은 auth_expired, error 계열뿐이다
    var isIssue: Bool { kind.hasPrefix("auth_expired") || kind.hasPrefix("error") }
    var isAuthExpired: Bool { kind.hasPrefix("auth_expired") }
    var isRevoked: Bool { kind.hasPrefix("auth_expired:revoked") }
    var isRateLimited: Bool { kind.hasPrefix("error:rate_limited") }
    var isAccessDenied: Bool { kind.hasPrefix("error:access_denied") }
    var needsSetup: Bool { kind.hasPrefix("error:credentials_missing") }
    /// 수집기가 Claude Code의 토큰만 빈 자격증명 껍데기를 확인했다: 로그인이 끝났고 /login이 필요하다.
    /// credentials_missing의 하위 상태라 구버전 앱은 설정 안내(needsSetup)로 읽는다.
    var isSignedOut: Bool { kind.hasPrefix("error:credentials_missing:signed_out") }

    var consecutiveFailures: Int? {
        guard let raw = parameter("failures"), let count = Int(raw), count > 0 else { return nil }
        return count
    }

    /// 수집기가 다음 요청을 보낼 시각(유닉스 초). 형식이 이상하면 nil
    var retryAt: Date? {
        guard let raw = parameter("retry_at"), let seconds = TimeInterval(raw),
              seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 수집기가 보낼 수 있는 가장 먼 재시도 시각까지의 거리. 수집기는 Retry-After를 하루로 자른 뒤
    /// 60초 여유를 더한다(collect.js RETRY_AFTER_CAP_S, RATE_LIMIT_MARGIN_S). 그쪽이 바뀌면 함께 바꾼다.
    static let maxRetryDelay: TimeInterval = 86400 + 60

    /// 안내에 쓸 만한 재시도 시각. 이미 지났으면 곧 다시 시도하는 중이라 시각을 말하지 않는다.
    /// 수집기가 보낼 수 있는 범위(maxRetryDelay)에 PC 시계가 조금 앞서는 정도(futureSlack)를 더한 것보다
    /// 먼 값은 단위가 틀린 값으로 보고 버린다.
    func pendingRetry(at now: Date) -> Date? {
        guard let retryAt, retryAt > now,
              retryAt.timeIntervalSince(now) <= Self.maxRetryDelay + ChargeFreshness.futureSlack else { return nil }
        return retryAt
    }

    /// 재시도 시각 표기, 오늘이면 시각만, 날짜가 바뀌면 날짜도 함께
    static func retryTimeText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 수집기 버전("x.y.z"). 빌드 메타데이터(+...)는 무시하고, 프리릴리스(-...)는 같은 코어보다 낮다.
/// 숫자가 아닌 조각이 있거나 네 자리 이상이면 읽지 않는다(nil).
struct CollectorVersion: Comparable {
    let core: [Int]
    let isPrerelease: Bool

    /// 스스로 업데이트하는 첫 수집기. 이보다 낮은 설치는 사용자가 한 번 직접 업데이트해야 한다.
    static let selfUpdating = CollectorVersion("0.2.0")!
    /// 401을 만료(auth_expired)와 폐기(auth_expired:revoked)로 나눠 보내는 첫 수집기
    static let reportsRevokedLogin = CollectorVersion("0.2.0")!

    init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("v") { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        var prerelease = false
        if let dash = text.firstIndex(of: "-") {
            prerelease = true
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        core = numbers
        isPrerelease = prerelease
    }

    static func < (lhs: CollectorVersion, rhs: CollectorVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

/// 동시에 활성인 5시간 블록을 기기별로 잃지 않고 전달한다.
/// `UsagePayload.live`는 구버전 앱·위젯 호환용 대표 블록으로 계속 유지한다.
struct DeviceActiveBlock: Codable, Identifiable {
    let deviceId: String
    let deviceLabel: String?
    let block: ActiveBlock
    let collectedAt: String?

    var id: String { deviceId }
}

struct ActiveBlock: Codable {
    let costUSD: Double
    let totalTokens: Int
    let startTime: String
    let endTime: String
    let models: [String]?
    let burnRate: BurnRate?
    let projection: Projection?

    struct BurnRate: Codable {
        let costPerHour: Double
    }

    struct Projection: Codable {
        let remainingMinutes: Int
        let totalCost: Double
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ s: String) -> Date? {
        Self.iso.date(from: s) ?? {
            let f = ISO8601DateFormatter()
            return f.date(from: s)
        }()
    }

    var start: Date? { Self.parse(startTime) }
    var end: Date? { Self.parse(endTime) }

    /// 끝 시각을 못 읽으면 만료로 본다, 만료 아님으로 두면 그 블록이 영영 안 끝나고
    /// live 게이지를 계속 차지한다 (표시를 잃는 쪽이 낡은 값을 붙잡는 쪽보다 낫다)
    var isExpired: Bool {
        guard let e = end else { return true }
        return e < Date()
    }

    /// 5시간 창에서 경과한 비율 (0...1)
    var windowProgress: Double {
        guard let s = start, let e = end, e > s else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(s) / e.timeIntervalSince(s)))
    }
}

extension NumberFormatter {
    static let usd: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()
}

func fmtUSD(_ v: Double) -> String {
    NumberFormatter.usd.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
}

func fmtTokens(_ v: Int) -> String {
    switch v {
    case 1_000_000...: return String(format: "%.1fM", Double(v) / 1_000_000)
    case 1_000...: return String(format: "%.1fK", Double(v) / 1_000)
    default: return "\(v)"
    }
}
