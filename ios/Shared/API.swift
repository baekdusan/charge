import Foundation

struct UsagePayload: Codable {
    let generatedAt: String?
    let daily: [DailyUsage]
    let live: ActiveBlock?
    let providers: [Provider]?
}

enum ChargeError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Data source (Gist URL) is not set.")
        }
    }
}

// 데이터 계층 추상화 — Supabase 등으로 백엔드를 바꿀 땐 이 파일만 교체한다.
enum ChargeAPI {
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    static func fetchAll() async throws -> UsagePayload {
        guard let base = ChargeConfig.gistRawURL else { throw ChargeError.notConfigured }
        // 쿼리 파라미터로 CDN 캐시를 우회해 항상 최신 리비전을 받는다
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let payload = try decoder.decode(UsagePayload.self, from: data)
        ChargeConfig.defaults.set(data, forKey: "lastPayload")
        return payload
    }

    /// 네트워크 실패 시 마지막 성공 페이로드로 폴백 (위젯이 $0으로 오표시되는 것 방지)
    static func fetchAllOrCached() async -> UsagePayload? {
        if let fresh = try? await fetchAll() { return fresh }
        guard let data = ChargeConfig.defaults.data(forKey: "lastPayload") else { return nil }
        return try? decoder.decode(UsagePayload.self, from: data)
    }
}
