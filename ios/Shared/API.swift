import Foundation

struct UsagePayload: Codable {
    let generatedAt: String?
    let daily: [DailyUsage]
    let live: ActiveBlock?
    let providers: [Provider]?
    let devices: [CollectorDevice]?
}

enum ChargeError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Sign in to see your usage.")
        }
    }
}

// 데이터 계층 추상화 — 백엔드를 바꿀 땐 이 파일만 교체한다. (Supabase PostgREST)
enum ChargeAPI {
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// 캐시는 자체 인코딩이라 키 전략 없이 대칭으로 저장/복원한다 ("costUSD" 같은 키의 왕복 깨짐 방지)
    private static let cacheKey = "lastPayloadV2"

    /// 로그아웃 등 계정 전환 시 이전 계정 데이터가 남지 않게 캐시를 비운다
    static func clearCache() {
        ChargeConfig.defaults.removeObject(forKey: cacheKey)
    }

    /// 계정 모드(charge_live)용 행 — v1 LiveRow와 달리 id 컬럼이 없다
    private struct AccountLiveRow: Codable {
        let activeBlock: ActiveBlock?
        let updatedAt: String?
    }

    static func fetchAll() async throws -> UsagePayload {
        guard ChargeAuth.session != nil, let cloud = ChargeAuth.cloud else {
            throw ChargeError.notConfigured
        }
        let payload = try await fetchAccount(cloud)
        if let data = try? JSONEncoder().encode(payload) {
            ChargeConfig.defaults.set(data, forKey: cacheKey)
        }
        return payload
    }

    private static func fetchAccount(_ cloud: (url: URL, anon: String)) async throws -> UsagePayload {
        let jwt = try await ChargeAuth.validAccessToken()
        // UI가 쓰는 최대 기간(스트릭 70일)보다 넉넉한 범위만 조회 —
        // 무제한 오름차순 조회는 PostgREST 1,000행 상한에 걸리면 최신 데이터가 잘린다
        let since = ChargeDate.day.string(from: Calendar.current.date(byAdding: .day, value: -120, to: Date())!)
        async let daily: [DailyUsage] = get(cloud.url, cloud.anon, "charge_daily?select=*&order=period.asc&period=gte.\(since)", bearer: jwt)
        async let liveRows: [AccountLiveRow] = get(cloud.url, cloud.anon, "charge_live?select=*&order=updated_at.desc", bearer: jwt)
        async let providerRows: [Provider] = get(cloud.url, cloud.anon, "charge_providers?select=*&order=id.asc", bearer: jwt)
        async let deviceRows: [CollectorDevice] = get(
            cloud.url,
            cloud.anon,
            "charge_devices?select=id,label,last_seen_at&order=last_seen_at.desc.nullslast",
            bearer: jwt
        )
        // 디바이스별 live 중 만료 안 된 가장 최신 블록 (여러 머신이 각자 보고)
        let lives = try await liveRows
        let activeLive = lives.first { row in
            guard let block = row.activeBlock else { return false }
            return !block.isExpired
        }?.activeBlock
        return UsagePayload(
            generatedAt: lives.first?.updatedAt,
            daily: mergeDaily(try await daily),
            live: activeLive,
            providers: try await providerRows,
            devices: try await deviceRows
        )
    }

    /// 머신(디바이스)별 행을 날짜 기준으로 합산 — 여러 컴퓨터에서 수집해도 비용이 합쳐져 보인다
    private static func mergeDaily(_ rows: [DailyUsage]) -> [DailyUsage] {
        var byDay: [String: DailyUsage] = [:]
        for r in rows {
            if let e = byDay[r.period] {
                byDay[r.period] = DailyUsage(
                    period: r.period,
                    totalCost: e.totalCost + r.totalCost,
                    totalTokens: e.totalTokens + r.totalTokens,
                    inputTokens: e.inputTokens + r.inputTokens,
                    outputTokens: e.outputTokens + r.outputTokens,
                    cacheReadTokens: e.cacheReadTokens + r.cacheReadTokens,
                    cacheCreationTokens: e.cacheCreationTokens + r.cacheCreationTokens,
                    models: e.models + r.models
                )
            } else {
                byDay[r.period] = r
            }
        }
        return byDay.values.sorted { $0.period < $1.period }
    }

    /// 네트워크 실패 시 마지막 성공 페이로드로 폴백 (위젯이 $0으로 오표시되는 것 방지)
    static func fetchAllOrCached() async -> UsagePayload? {
        if let fresh = try? await fetchAll() { return fresh }
        guard let data = ChargeConfig.defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(UsagePayload.self, from: data)
    }

    private static func get<T: Decodable>(_ base: URL, _ key: String, _ pathQuery: String, bearer: String? = nil) async throws -> T {
        guard let url = URL(string: "\(base.absoluteString)/rest/v1/\(pathQuery)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer ?? key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }
}
