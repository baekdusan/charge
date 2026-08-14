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
}

struct CollectorDevice: Codable, Identifiable {
    let id: String
    let label: String?
    let lastSeenAt: String?
    /// 프로바이더 id → 수집 상태 ("ok" | "auth_expired" | "stale" | "error") — 레거시 수집기는 nil
    var collectStatus: [String: String]? = nil

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

    /// 최신 수집기인데 볼 프로바이더를 하나도 못 찾은 기기(자격증명이 없는 PC)는 빈 맵을 올린다.
    /// 구버전과 같이 묶어 "업데이트하세요"라고 하면 해봐야 아무것도 안 바뀌는 안내가 된다.
    var hasNoProviders: Bool { collectStatus?.isEmpty == true }

    /// 수집 실패 프로바이더 한 건 — 안내 문구에 쓸 표시 이름과 상태
    struct CollectIssue: Identifiable {
        let providerId: String
        let providerName: String
        let status: String
        var id: String { providerId }
        var isAuthExpired: Bool { status.hasPrefix("auth_expired") }
    }

    /// 경고로 보여줄 항목만 추린다 — "auth_expired"/"error"류(접두 매칭)만 경고.
    /// "ok"·"stale"은 물론 미래에 추가될 모르는 상태값도 경고로 치지 않는다 (구버전 앱 오경보 방지)
    var collectIssues: [CollectIssue] {
        (collectStatus ?? [:])
            .filter { $0.value.hasPrefix("auth_expired") || $0.value.hasPrefix("error") }
            .sorted { $0.key < $1.key }
            .map { pid, status in
                CollectIssue(
                    providerId: pid,
                    providerName: ChargeConfig.knownProviders[pid] ?? pid.capitalized,
                    status: status
                )
            }
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
