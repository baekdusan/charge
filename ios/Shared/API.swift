import Foundation

struct UsagePayload: Codable {
    let generatedAt: String?
    let daily: [DailyUsage]
    let live: ActiveBlock?
    let providers: [Provider]?
}

// 데이터 계층 추상화 — Supabase 등으로 백엔드를 바꿀 땐 이 파일만 교체한다.
enum ChargeAPI {
    static func fetchAll() async throws -> UsagePayload {
        // 쿼리 파라미터로 CDN 캐시를 우회해 항상 최신 리비전을 받는다
        var comps = URLComponents(url: Secrets.gistRawURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsagePayload.self, from: data)
    }
}
