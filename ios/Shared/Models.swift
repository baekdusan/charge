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

struct Provider: Codable, Identifiable {
    let id: String
    let name: String
    let session: RateWindow?
    let weekly: RateWindow?
    let extras: [ExtraWindow]?
    let status: ProviderStatus?
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

    init(percent: Double, resetsAt: String?, windowMinutes: Int? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
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

struct LiveRow: Codable {
    let id: Int
    let activeBlock: ActiveBlock?
    let updatedAt: String
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

    var isExpired: Bool {
        guard let e = end else { return false }
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
