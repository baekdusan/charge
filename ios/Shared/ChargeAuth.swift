import Foundation
import WidgetKit

/// 호스팅(멀티유저) 백엔드 세션 — Apple 로그인으로 발급받은 Supabase Auth 토큰
struct ChargeSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
}

enum ChargeAuth {
    /// 번들 CloudConfig.txt(1행: URL, 2행: anon key) — 없으면 계정 모드 비활성 (셀프호스팅 전용 빌드)
    static let cloud: (url: URL, anon: String)? = {
        guard let p = Bundle.main.url(forResource: "CloudConfig", withExtension: "txt"),
              let s = try? String(contentsOf: p, encoding: .utf8) else { return nil }
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let url = URL(string: lines[0]) else { return nil }
        return (url, lines[1])
    }()

    /// 앱·위젯이 공유하는 세션 (App Group)
    static var session: ChargeSession? {
        get {
            guard let data = ChargeConfig.defaults.data(forKey: "cloudSession") else { return nil }
            return try? JSONDecoder().decode(ChargeSession.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                ChargeConfig.defaults.set(data, forKey: "cloudSession")
            } else {
                ChargeConfig.defaults.removeObject(forKey: "cloudSession")
            }
        }
    }

    /// 세션과 함께 계정에 귀속된 로컬 데이터를 모두 지운다
    /// (캐시가 남으면 위젯이 이전 계정의 사용량을 계속 보여준다)
    static func signOut() {
        session = nil
        ChargeAPI.clearCache()
        ChargeConfig.defaults.removeObject(forKey: "knownProviders")
        ChargeConfig.defaults.removeObject(forKey: "hiddenProviders")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Sign in with Apple의 identity token을 Supabase Auth 세션으로 교환
    static func signIn(appleIDToken: String) async throws {
        guard let cloud else { throw ChargeError.notConfigured }
        let body = ["provider": "apple", "id_token": appleIDToken]
        session = try await tokenRequest(cloud, grantType: "id_token", body: body)
    }

    /// 유효한 access token 반환 — 만료 임박이면 refresh
    static func validAccessToken() async throws -> String {
        guard let cloud, let s = session else { throw ChargeError.notConfigured }
        if s.expiresAt > Date().addingTimeInterval(60) { return s.accessToken }
        let refreshed = try await tokenRequest(cloud, grantType: "refresh_token",
                                               body: ["refresh_token": s.refreshToken])
        session = refreshed
        return refreshed.accessToken
    }

    /// 수집기 페어링 코드 발급 (10분 유효, 일회용)
    static func createPairingCode() async throws -> String {
        guard let cloud else { throw ChargeError.notConfigured }
        let jwt = try await validAccessToken()
        var req = URLRequest(url: cloud.url.appendingPathComponent("rest/v1/rpc/charge_create_pairing_code"))
        req.httpMethod = "POST"
        req.setValue(cloud.anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let code = try? JSONDecoder().decode(String.self, from: data) else {
            throw URLError(.badServerResponse)
        }
        return code
    }

    // MARK: 내부

    private struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: TokenUser?
        struct TokenUser: Codable { let email: String? }
    }

    private static func tokenRequest(_ cloud: (url: URL, anon: String),
                                     grantType: String,
                                     body: [String: String]) async throws -> ChargeSession {
        var comps = URLComponents(url: cloud.url.appendingPathComponent("auth/v1/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(cloud.anon, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let tok = try d.decode(TokenResponse.self, from: data)
        return ChargeSession(accessToken: tok.accessToken,
                             refreshToken: tok.refreshToken,
                             expiresAt: Date().addingTimeInterval(tok.expiresIn),
                             email: tok.user?.email ?? session?.email)
    }
}
