import Foundation
import WidgetKit

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

    /// 캐시·세대 번호는 App Group 파일로 저장한다 — UserDefaults는 프로세스 간 전파가
    /// 비동기라, 앱의 무효화(기기 삭제·로그아웃)를 위젯이 못 보고 낡은 데이터를 보여주거나
    /// 진행 중 조회가 지운 캐시를 되살릴 수 있다. 파일 삭제/원자적 쓰기는 즉시 보인다.
    private static var cacheFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite)?
            .appendingPathComponent("payload-cache.json")
    }

    private static var generationFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite)?
            .appendingPathComponent("data-generation")
    }

    private static var dataGeneration: Int {
        guard let url = generationFileURL,
              let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 캐시는 기록 당시의 세대 번호와 함께 저장한다 — 무효화(세대 증가)를 건너뛴 낡은 기록은
    /// 읽기 단계에서 걸러지므로, 늦게 도착한 조회가 캐시를 "덮어써도" 해가 없다
    private struct CacheEnvelope: Codable {
        let generation: Int
        let payload: UsagePayload
    }

    private static var cachedPayload: UsagePayload? {
        if let url = cacheFileURL, let data = try? Data(contentsOf: url) {
            // 빈 파일 = 무효화 표식(로그아웃·기기 삭제) — 구버전 폴백으로 내려가면 안 된다
            guard let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
                  envelope.generation == dataGeneration else { return nil }
            return envelope.payload
        }
        // 파일이 아예 없는 것은 업그레이드 직후뿐 — 그때만 구버전 저장 위치로 폴백해
        // 첫 조회가 실패해도 위젯이 $0으로 비지 않게 한다
        guard let data = ChargeConfig.defaults.data(forKey: "lastPayloadV2") else { return nil }
        return try? JSONDecoder().decode(UsagePayload.self, from: data)
    }

    /// 캐시 검사·기록·무효화를 프로세스 간에 직렬화하는 짧은 잠금 (보유 시간 = 파일 쓰기 순간)
    private static func withCacheLock<T>(_ body: () -> T) -> T {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ChargeConfig.suite) else {
            return body()
        }
        let fd = open(dir.appendingPathComponent(".cache-lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private static func writeCache(_ payload: UsagePayload, generation: Int) {
        guard let url = cacheFileURL,
              let data = try? JSONEncoder().encode(CacheEnvelope(generation: generation, payload: payload)) else { return }
        withCacheLock {
            // 우리가 낡은 세대라면 쓰지 않는다 — 최신 조회가 이미 쓴 유효 캐시를
            // (읽기에서 거부될) 낡은 봉투로 덮어쓰면 오프라인 폴백이 사라진다
            guard dataGeneration == generation else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 로그아웃 등 계정 전환 시 이전 계정 데이터가 남지 않게 캐시를 비운다.
    /// 세대 번호도 올린다 — 비우기 전에 시작된 조회가 끝나서 낡은 페이로드를
    /// 도로 캐시에 쓰는 것을 fetchAll이 감지해 거부할 수 있게.
    static func clearCache() {
        withCacheLock {
            // 세대 번호를 먼저 올리고 캐시를 지운다 — 진행 중인 조회의 기록(writeCache)과는
            // 같은 잠금으로 배타되므로 낡은 페이로드가 이 뒤에 끼어들 수 없다
            if let url = generationFileURL {
                try? String(dataGeneration + 1).write(to: url, atomically: true, encoding: .utf8)
            }
            // 삭제 대신 빈 파일(무효화 표식)을 쓴다 — 파일이 없으면 읽기가 구버전 UserDefaults로
            // 폴백하는데, defaults 키 제거는 프로세스 간 전파가 비동기라 위젯이 지운 캐시를 되살린다
            if let url = cacheFileURL { try? Data().write(to: url, options: .atomic) }
        }
        // 구버전 저장 위치도 함께 정리
        ChargeConfig.defaults.removeObject(forKey: "lastPayloadV2")
    }

    /// 캐시가 무효화됐는지(기기 삭제 등) UI가 확인해 화면의 이전 스냅샷도 함께 비울 수 있게 한다
    static var hasCache: Bool { cachedPayload != nil }

    /// 계정 모드(charge_live)용 행 — v1 LiveRow와 달리 id 컬럼이 없다
    private struct AccountLiveRow: Codable {
        let activeBlock: ActiveBlock?
        let updatedAt: String?
    }

    static func fetchAll() async throws -> UsagePayload {
        // 데모 모드: 네트워크·로그인 없이 샘플 데이터 (위젯도 fetchAllOrCached를 거쳐 여기로 온다)
        if ChargeConfig.demoMode {
            // 느린 네트워크 흉내 — 취소 전파도 실제 URLSession처럼 겪도록 throw를 삼키지 않는다
            if let s = ChargeConfig.demoLatency {
                try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            }
            return DemoData.payload
        }
        guard ChargeAuth.session != nil, let cloud = ChargeAuth.cloud else {
            throw ChargeError.notConfigured
        }
        let generation = dataGeneration
        let payload = try await fetchAccount(cloud, jwt: ChargeAuth.validAccessToken())
        // 조회 시작 시점의 세대를 태그해 저장한다 — 조회 중 무효화가 있었다면
        // 낡은 세대 태그가 남아 읽기에서 걸러지므로 별도 되돌리기가 필요 없다
        writeCache(payload, generation: generation)
        // 화면에도 삭제/로그아웃 전 데이터를 적용하지 않는다 (다음 로드가 최신을 가져온다)
        guard dataGeneration == generation else { throw CancellationError() }
        return payload
    }

    private static func fetchAccount(_ cloud: (url: URL, anon: String), jwt: String) async throws -> UsagePayload {
        // UI가 쓰는 최대 기간(스트릭 70일)보다 넉넉한 범위만 조회 —
        // 무제한 오름차순 조회는 PostgREST 1,000행 상한에 걸리면 최신 데이터가 잘린다
        let since = ChargeDate.day.string(from: Calendar.current.date(byAdding: .day, value: -120, to: Date())!)
        async let daily: [DailyUsage] = get(cloud.url, cloud.anon, "charge_daily?select=*&order=period.asc&period=gte.\(since)", bearer: jwt)
        async let liveRows: [AccountLiveRow] = get(cloud.url, cloud.anon, "charge_live?select=*&order=updated_at.desc", bearer: jwt)
        async let providerRows: [Provider] = get(cloud.url, cloud.anon, "charge_providers?select=*&order=id.asc", bearer: jwt)
        async let deviceRows: [CollectorDevice] = get(
            cloud.url,
            cloud.anon,
            "charge_devices?select=id,label,last_seen_at,collect_status&order=last_seen_at.desc.nullslast",
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

    /// 기기 연결 해제 — RLS "own delete" 정책으로 본인 기기만 지워지고,
    /// 그 기기의 daily/live 행과 디바이스 토큰도 cascade로 함께 정리된다
    static func deleteDevice(id: String) async throws {
        guard let cloud = ChargeAuth.cloud else { throw ChargeError.notConfigured }
        let jwt = try await ChargeAuth.validAccessToken()
        guard let url = URL(string: "\(cloud.url.absoluteString)/rest/v1/charge_devices?id=eq.\(id)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(cloud.anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // 삭제된 기기의 기록이 남은 캐시는 즉시 비운다 — 후속 재조회가 실패해도
        // 위젯이 지워진 사용량을 계속 보여주지 않도록 (다음 성공 조회가 다시 채운다)
        clearCache()
        // 이미 렌더된 위젯 타임라인도 무효화 — 시트를 닫기 전에 앱을 백그라운드로 보내도
        // 위젯이 삭제된 사용량을 계속 보여주지 않게 한다
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 위젯용: 네트워크 실패 시 마지막 성공 페이로드로 폴백 (위젯이 $0으로 오표시되는 것 방지).
    /// 토큰 갱신은 앱과 공유하는 프로세스 간 잠금으로 직렬화되어 있어 위젯에서도 안전하다.
    static func fetchAllOrCached() async -> UsagePayload? {
        if let fresh = try? await fetchAll() { return fresh }
        return cachedPayload
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
