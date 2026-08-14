import Foundation
import WidgetKit

struct UsagePayload: Codable {
    let generatedAt: String?
    let daily: [DailyUsage]
    let live: ActiveBlock?
    var liveBlocks: [DeviceActiveBlock]? = nil
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

    /// 계정 모드(charge_live)용 행, v1 LiveRow와 달리 id 컬럼이 없다.
    /// collected_at(수집기가 실제로 블록을 읽은 시각)은 select=*로 함께 온다, 컬럼명을 나열하면
    /// 서버 마이그레이션이 배포보다 늦은 순간에 조회 전체가 400으로 죽는다.
    private struct AccountLiveRow: Codable {
        let deviceId: String
        let activeBlock: ActiveBlock?
        let updatedAt: String?
        var collectedAt: String? = nil

        private static let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let iso = ISO8601DateFormatter()

        private static func parse(_ s: String?) -> Date? {
            guard let s else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }

        var updatedDate: Date? { Self.parse(updatedAt) }
    }

    /// 새 백엔드는 기기별 원본 관측을 보존한다. payload는 수집기가 보낸 Provider 한 건이며
    /// 바깥 키들은 어느 기기가 언제 그 값을 보고했는지 나타낸다.
    private struct ProviderObservationRow: Codable {
        let deviceId: String
        let providerId: String
        let account: String
        let payload: Provider
        let collectedAt: String?
        let lastReportedAt: String
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
        // 앱이 먼저 배포돼도 구버전 DB의 404 때문에 전체 로드가 죽지 않게 optional 조회한다.
        async let observationRows: [ProviderObservationRow]? = optionalGet(
            cloud.url,
            cloud.anon,
            "charge_provider_observations?select=*&order=provider_id.asc,last_reported_at.desc",
            bearer: jwt
        )
        async let deviceRows: [CollectorDevice] = get(
            cloud.url,
            cloud.anon,
            "charge_devices?select=id,label,last_seen_at,collect_status&order=last_seen_at.desc.nullslast",
            bearer: jwt
        )
        // 디바이스별 live 중 만료 안 된 블록 하나 (여러 머신이 각자 보고).
        // "가장 최근에 업로드한 행"이 아니라 "블록 시작이 가장 늦은 행"을 고른다 , 
        // 수집이 깨진 기기가 캐시된 옛 블록을 5분마다 재업로드하면 updated_at 기준으로는
        // 그 낡은 블록이 계속 이겨 최대 5시간 동안 live 게이지를 차지한다.
        let lives = try await liveRows
        let activeLives = lives
            .filter { $0.activeBlock.map { !$0.isExpired } ?? false }
            .sorted { a, b in
                let sa = a.activeBlock?.start ?? .distantPast
                let sb = b.activeBlock?.start ?? .distantPast
                if sa != sb { return sa > sb }
                return (a.updatedDate ?? .distantPast) > (b.updatedDate ?? .distantPast)
            }
        let selectedLive = activeLives.first
        let devices = try await deviceRows
        let canonicalProviders = try await providerRows
        let observations = await observationRows
        let labels = deviceLabelsByID(devices)
        return UsagePayload(
            // 표시 중인 블록을 올린 행의 시각, lives.first는 선택된 블록과 무관한 다른 기기일 수 있다
            generatedAt: selectedLive?.collectedAt ?? selectedLive?.updatedAt ?? lives.first?.updatedAt,
            daily: mergeDaily(try await daily),
            live: selectedLive?.activeBlock,
            liveBlocks: activeLives.compactMap { row in
                guard let block = row.activeBlock else { return nil }
                return DeviceActiveBlock(
                    deviceId: row.deviceId,
                    deviceLabel: labels[row.deviceId],
                    block: block,
                    collectedAt: row.collectedAt ?? row.updatedAt
                )
            },
            providers: observations.map {
                mergeProviderObservations($0, canonical: canonicalProviders, devices: devices)
            } ?? canonicalProviders,
            devices: devices
        )
    }

    /// 같은 (provider, account)의 기기별 관측 중 실제 수집 시각이 가장 신선한 값을 카드로 삼는다.
    /// 아직 관측 테이블로 이행되지 않은 canonical 행도 합쳐, 오프라인 기기 데이터가 배포 순간
    /// 사라지지 않게 한다.
    private static func mergeProviderObservations(
        _ observations: [ProviderObservationRow],
        canonical: [Provider],
        devices: [CollectorDevice],
        now: Date = Date()
    ) -> [Provider] {
        let deviceByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let displayLabelByID = deviceLabelsByID(devices)
        let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let iso = ISO8601DateFormatter()
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            return isoFrac.date(from: value) ?? iso.date(from: value)
        }
        func key(_ provider: String, _ account: String?) -> String {
            "\(provider)\u{0}\(account ?? "")"
        }
        func isRetired(_ row: ProviderObservationRow) -> Bool {
            guard let device = deviceByID[row.deviceId], device.isTracking(at: now),
                  let reported = date(row.lastReportedAt), now.timeIntervalSince(reported) > 20 * 60,
                  let statuses = device.collectStatus else { return false }
            // 이 프로바이더 자체가 실패 중이면 마지막 정상 관측을 보존한다. 정상/낡음 또는
            // 최신 수집기에서 항목 자체가 사라진 경우에만 이 기기의 옛 계정 관측을 은퇴시킨다.
            guard let status = statuses[row.providerId] else { return true }
            return !status.hasPrefix("error") && !status.hasPrefix("auth_expired")
        }

        let grouped = Dictionary(grouping: observations) { key($0.providerId, $0.account) }
        let canonicalByKey = Dictionary(uniqueKeysWithValues: canonical.map { (key($0.id, $0.account), $0) })
        var resolved: [Provider] = []
        var observationKeys = Set<String>()
        for (groupKey, rows) in grouped {
            observationKeys.insert(groupKey)
            let active = rows.filter { !isRetired($0) }
            guard let newest = active.max(by: { a, b in
                let da = date(a.collectedAt) ?? date(a.lastReportedAt) ?? .distantPast
                let db = date(b.collectedAt) ?? date(b.lastReportedAt) ?? .distantPast
                return da < db
            }) else { continue }
            let observedDate = date(newest.collectedAt) ?? date(newest.lastReportedAt) ?? .distantPast
            // 순차 배포 중에는 아직 구버전 수집기만 canonical을 갱신할 수 있다. 그 값이 더
            // 신선하면 관측 테이블에 이미 키가 있다는 이유만으로 버리지 않는다.
            let canonicalCandidate = canonicalByKey[groupKey]
            let useCanonical = canonicalCandidate
                .flatMap { date($0.collectedAt) }
                .map { $0 > observedDate } ?? false
            let base = useCanonical ? canonicalCandidate! : newest.payload
            let sourceDeviceID = useCanonical ? canonicalCandidate?.deviceId : newest.deviceId
            var labels = active.compactMap { displayLabelByID[$0.deviceId] }
            if let sourceDeviceID, let label = displayLabelByID[sourceDeviceID], !labels.contains(label) {
                labels.append(label)
            }
            labels.sort()
            resolved.append(Provider(
                id: base.id,
                name: base.name,
                plan: base.plan,
                session: base.session,
                weekly: base.weekly,
                extras: base.extras,
                status: base.status,
                account: base.account ?? newest.account,
                deviceId: sourceDeviceID,
                deviceLabel: sourceDeviceID.flatMap { displayLabelByID[$0] },
                deviceLabels: labels,
                collectedAt: base.collectedAt ?? newest.collectedAt
            ))
        }
        // 관측이 한 번도 생성되지 않은 키는 구버전/장기 오프라인 기기일 수 있으므로 보존한다.
        resolved.append(contentsOf: canonical.filter { !observationKeys.contains(key($0.id, $0.account)) })
        return resolved.sorted { ($0.id, $0.account ?? "") < ($1.id, $1.account ?? "") }
    }

    /// 호스트명이 같은 별도 설치도 화면에서 구분할 수 있게, 중복 라벨에만 짧은 기기 id를 붙인다.
    private static func deviceLabelsByID(_ devices: [CollectorDevice]) -> [String: String] {
        let baseByID = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, device.shortLabel ?? device.label ?? String(localized: "Unnamed device"))
        })
        let counts = Dictionary(grouping: baseByID.values, by: { $0 }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: devices.map { device in
            let base = baseByID[device.id]!
            let label = counts[base, default: 0] > 1
                ? "\(base) · \(device.id.prefix(4).uppercased())"
                : base
            return (device.id, label)
        })
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

    private static func optionalGet<T: Decodable>(
        _ base: URL,
        _ key: String,
        _ pathQuery: String,
        bearer: String? = nil
    ) async -> T? {
        try? await get(base, key, pathQuery, bearer: bearer)
    }
}
