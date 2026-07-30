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

    /// 세션 저장 파일 (App Group 컨테이너) — UserDefaults는 프로세스 간 전파가 비동기라
    /// refresh 잠금을 잡은 직후의 재확인 읽기가 낡은 토큰을 볼 수 있다. 파일은 원자적으로
    /// 쓰고 항상 디스크에서 읽으므로 잠금과 같은 경계 안에서 최신 값이 보장된다.
    private static var sessionFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite)?
            .appendingPathComponent("session.json")
    }

    /// 앱·위젯이 공유하는 세션 (App Group)
    static var session: ChargeSession? {
        get {
            if let url = sessionFileURL, let data = try? Data(contentsOf: url) {
                return try? JSONDecoder().decode(ChargeSession.self, from: data)
            }
            // 구버전 저장 위치(UserDefaults)에서 읽기 — 다음 저장 때 파일로 이행된다
            guard let data = ChargeConfig.defaults.data(forKey: "cloudSession") else { return nil }
            return try? JSONDecoder().decode(ChargeSession.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                if let url = sessionFileURL {
                    try? data.write(to: url, options: .atomic)
                    ChargeConfig.defaults.removeObject(forKey: "cloudSession")
                } else {
                    ChargeConfig.defaults.set(data, forKey: "cloudSession")
                }
            } else {
                // 삭제 대신 빈 파일을 원자적으로 쓴다 — 파일이 없으면 getter가 구버전
                // UserDefaults로 폴백하는데, defaults 키 제거는 프로세스 간 전파가 비동기라
                // 위젯이 로그아웃 직후에도 낡은 세션을 읽을 수 있다
                if let url = sessionFileURL { try? Data().write(to: url, options: .atomic) }
                ChargeConfig.defaults.removeObject(forKey: "cloudSession")
            }
        }
    }

    /// 로그아웃마다 1씩 증가 — 토큰 회전(같은 계정)과 달리 계정 경계가 바뀔 때만 변한다.
    /// 로그아웃 전에 시작된 로드가 늦게 도착해 이전 계정의 알림을 예약하는 것을 막는 데 쓴다.
    static var sessionEpoch: Int { ChargeConfig.defaults.integer(forKey: "sessionEpoch") }

    /// 세션 파일 쓰기 전용 짧은 잠금 — refresh의 "비교 후 저장"과 로그아웃/로그인의 쓰기가
    /// 원자적으로 배타되게 한다. 보유 시간은 파일 쓰기 순간뿐이라 블로킹 잠금이어도 무해하다.
    /// (refresh 전체를 감싸는 .refresh-lock과 별개 — 그쪽은 네트워크 왕복 동안 유지된다)
    @discardableResult
    static func withSessionWriteLock<T>(_ body: () -> T) -> T {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite) else {
            return body()
        }
        let fd = open(dir.appendingPathComponent(".session-write-lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// 세션과 함께 계정에 귀속된 로컬 데이터를 모두 지운다
    /// (캐시가 남으면 위젯이 이전 계정의 사용량을 계속 보여준다)
    static func signOut() {
        withSessionWriteLock { session = nil }
        finishSignOut()
    }

    /// 세션이 이미 (잠금 안에서) 지워진 뒤의 나머지 정리 — refresh 실패 경로와 공용
    private static func finishSignOut() {
        ChargeConfig.defaults.set(sessionEpoch + 1, forKey: "sessionEpoch")
        ChargeAPI.clearCache()
        ChargeConfig.resetAccountScoped()
        // 예약된 리셋 알림·프로바이더별 뮤트도 함께 제거 — 남겨두면 로그아웃 후
        // 이전 계정의 알림이 울리거나, 다음 계정에서 같은 id가 소리 없이 뮤트된다
        Task { @MainActor in ResetNotifications.cancelAll() }
        ResetNotifications.mutedProviders = []
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Sign in with Apple의 identity token을 Supabase Auth 세션으로 교환
    static func signIn(appleIDToken: String) async throws {
        guard let cloud else { throw ChargeError.notConfigured }
        let body = ["provider": "apple", "id_token": appleIDToken]
        let newSession = try await tokenRequest(cloud, grantType: "id_token", body: body)
        withSessionWriteLock { session = newSession }
    }

    /// 유효한 access token 반환 — 만료 임박이면 refresh.
    /// refresh token이 무효(폐기·회전 충돌)면 세션을 지운다 — 죽은 세션으로
    /// 갱신을 반복하면 Auth 엔드포인트 rate limit에 걸려 재로그인까지 막힌다.
    static func validAccessToken() async throws -> String {
        guard let cloud, let s = session else { throw ChargeError.notConfigured }
        if s.expiresAt > Date().addingTimeInterval(60) { return s.accessToken }
        return try await sharedRefresh(cloud).accessToken
    }

    /// 진행 중인 refresh — 같은 프로세스의 동시 호출은 하나의 요청을 공유한다.
    /// 각자 refresh하면 Supabase의 토큰 회전 때문에 늦게 실패한 쪽이
    /// 방금 발급된 유효 세션을 지워버릴 수 있다.
    @MainActor private static var inflightRefresh: Task<ChargeSession, Error>?

    @MainActor
    private static func sharedRefresh(_ cloud: (url: URL, anon: String)) async throws -> ChargeSession {
        if let inflight = inflightRefresh { return try await inflight.value }
        let task = Task<ChargeSession, Error> {
            try await withRefreshLock {
                // 잠금을 기다리는 사이 (같은 프로세스든 다른 프로세스든) 갱신이 끝났을 수 있다
                if let current = session, current.expiresAt > Date().addingTimeInterval(60) { return current }
                guard let stale = session else { throw ChargeError.notConfigured }
                do {
                    let refreshed = try await tokenRequest(cloud, grantType: "refresh_token",
                                                           body: ["refresh_token": stale.refreshToken])
                    // 갱신 중 로그아웃/계정 전환이 있었으면 결과를 버린다 — 비교와 저장을
                    // 세션 쓰기 잠금 안에서 함께 해 다른 프로세스의 로그아웃 쓰기와 원자적으로 배타한다
                    let stored = withSessionWriteLock { () -> Bool in
                        guard session?.refreshToken == stale.refreshToken else { return false }
                        session = refreshed
                        return true
                    }
                    guard stored else { throw ChargeError.notConfigured }
                    return refreshed
                } catch let e as URLError where e.code == .userAuthenticationRequired {
                    // 로그아웃됐으면 아무것도 하지 않고, 로그인이 세션을 교체했다면 그쪽을 신뢰한다.
                    // 비교와 삭제도 쓰기 잠금 안에서 원자적으로 — 잠금 없이 signOut()을 부르면
                    // 그 사이 완료된 로그인의 새 세션을 지워버릴 수 있다.
                    enum InvalidTokenOutcome {
                        case alreadySignedOut
                        case replaced(ChargeSession)
                        case clearedOurs
                    }
                    let outcome = withSessionWriteLock { () -> InvalidTokenOutcome in
                        guard let current = session else { return .alreadySignedOut }
                        if current.refreshToken != stale.refreshToken { return .replaced(current) }
                        session = nil
                        return .clearedOurs
                    }
                    switch outcome {
                    case .replaced(let current):
                        return current
                    case .alreadySignedOut:
                        throw ChargeError.notConfigured
                    case .clearedOurs:
                        finishSignOut()
                        throw ChargeError.notConfigured
                    }
                }
            }
        }
        inflightRefresh = task
        defer { inflightRefresh = nil }
        return try await task.value
    }

    /// 앱·위젯이 서로 다른 프로세스에서 동시에 refresh하지 않도록 App Group 파일 잠금으로 직렬화.
    /// Supabase는 refresh token을 1회용으로 회전시키므로, 동시 갱신은 늦게 도착한 쪽이
    /// 세션 계열 전체를 폐기시킬 수 있다. 잠금을 얻은 뒤에는 다른 프로세스가 이미 갱신을
    /// 끝냈는지 저장소를 다시 읽어 확인한다.
    private static func withRefreshLock<T>(_ body: () async throws -> T) async throws -> T {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite) else {
            return try await body()
        }
        let fd = open(dir.appendingPathComponent(".refresh-lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try await body() }
        defer { close(fd) }
        // 다른 프로세스가 refresh 중이면 끝날 때까지 짧게 재시도 (논블로킹 — 스레드를 잡지 않는다).
        // 잠금 보유 프로세스가 백그라운드로 정지되면 잠금이 풀리지 않을 수 있으므로
        // 최대 10초까지만 기다리고 일시 오류로 처리한다 — 호출자(위젯)는 캐시로 폴백한다.
        var attempts = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            attempts += 1
            guard attempts < 50 else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    /// "보여줄 데이터가 있는가" — 로그인 세션 또는 데모 모드.
    /// 뷰가 session과 demoMode를 손으로 조합하면 극성이 갈라지기 쉬워 여기로 모은다.
    /// ("로그인했는가"가 필요한 곳은 계속 session을 직접 본다 — 다른 질문이다.)
    static var hasUsableData: Bool { session != nil || ChargeConfig.demoMode }

    /// 인증된 PostgREST RPC 호출 (빈 인자) — 헤더 세트·성공 판정(2xx)의 정본
    private static func rpc(_ name: String) async throws -> Data {
        guard let cloud else { throw ChargeError.notConfigured }
        let jwt = try await validAccessToken()
        var req = URLRequest(url: cloud.url.appendingPathComponent("rest/v1/rpc/\(name)"))
        req.httpMethod = "POST"
        req.setValue(cloud.anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// 계정 삭제 (App Store 요건) — 서버의 auth.users 행을 지우면 사용량·기기·프로바이더
    /// 데이터가 전부 cascade로 삭제된다. 성공하면 로컬도 로그아웃과 동일하게 정리한다.
    static func deleteAccount() async throws {
        _ = try await rpc("charge_delete_account")
        signOut()
    }

    /// 수집기 페어링 코드 발급 (10분 유효, 일회용)
    static func createPairingCode() async throws -> String {
        let data = try await rpc("charge_create_pairing_code")
        guard let code = try? JSONDecoder().decode(String.self, from: data) else {
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
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            // 400/401/403 = 자격증명 자체가 무효(영구) — 그 외(408/429/5xx 등)는
            // 일시 장애로 취급한다. 여기서 넓게 잡으면 프록시의 일시적 4xx에도 세션이 지워진다.
            if [400, 401, 403].contains(http.statusCode) {
                throw URLError(.userAuthenticationRequired)
            }
            throw URLError(.badServerResponse)
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
