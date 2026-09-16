import Foundation

/// 데모 모드 샘플 데이터 — 네트워크·로그인 없이 앱·위젯의 모든 UI를 채운다.
/// (App Store 심사원이 수집기 없이 앱을 평가할 수 있어야 하고,
///  위젯 갤러리 프리뷰도 같은 데이터를 쓴다 — 픽스처의 정본은 이 파일 하나다)
enum DemoData {
    /// 접근 시점 기준으로 매번 다시 만든다, 프로세스 시작 시각에 고정하면 앱을 20분만 켜둬도
    /// collectedAt이 staleAge를 넘겨 모든 카드에 "Data from N min ago"가 붙고 위젯 게이지가 흐려진다.
    /// (같은 이유로 lastSeenAt은 12분 뒤 "추적 중"이 풀리고, live 블록은 3.2시간 뒤 만료된다.
    ///  심사, 스크린샷이 통째로 그 상태로 걸린다.)
    /// 다만 기준 시각은 수집 주기(5분) 격자로 내림해 같은 격자 안에서는 값이 완전히 동일하다.
    /// resetsAt이 호출마다 흔들리면 위젯 지문이 매번 달라져 60초 폴링이 내용 변화 없이도
    /// reloadAllTimelines를 반복하게 된다. 카운트다운 표시는 어차피 뷰(TimelineView)가 현재 시각으로 그린다.
    static var payload: UsagePayload { make(now: gridNow(), arguments: CommandLine.arguments) }

    private static let iso = ISO8601DateFormatter()

    /// 데모 값의 기준 시각, 실제 수집 주기와 같은 5분 격자로 내린다
    private static func gridNow(_ date: Date = Date()) -> Date {
        let grid: TimeInterval = 5 * 60
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / grid).rounded(.down) * grid)
    }

    /// 런치 인자는 로직 테스트가 주입할 수 있게 인자로 받는다(앱은 CommandLine.arguments를 넘긴다)
    static func make(now: Date, arguments: [String]) -> UsagePayload {
        func at(_ seconds: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(seconds)) }
        let args = arguments

        // 화면 확인용 픽스처, 데모 모드의 이 프로세스에만 적용된다(인자가 없으면 기본 데모 데이터 그대로다).
        // -charge-demo-quota-protection: Claude 주간 한도 100%, 어제와 오늘을 모두 덮는 차단 구간, 그 이틀의
        // Claude 사용량 0. Claude 탭의 스트릭에 "오늘 스트릭 보호됨"과 보호일 칸이 그려진다.
        let quotaProtection = args.contains("-charge-demo-quota-protection")
        // -charge-demo-stale-claude: 사흘 전에 수집된 Claude 스냅샷, 리셋 시각 없는 세션 창.
        // 세션 게이지가 0%가 아니라 값 미상("최근 데이터 없음")으로 그려진다.
        let staleClaude = args.contains("-charge-demo-stale-claude")

        // 세션 창: 5시간 중 3시간 경과(60%), 주간 창: 7일 중 4.2일 경과
        var claudeSession = RateWindow(percent: 34, resetsAt: at(2 * 3600), windowMinutes: 300)
        var claudeWeekly = RateWindow(percent: 62, resetsAt: at(2.8 * 86400), windowMinutes: 10_080)
        var claudeCollectedAt = at(-90)
        let blockedWeeklyReset = at(1.3 * 86400)
        if quotaProtection {
            // 주간 한도에 막히면 세션은 쉬는 중이라 리셋 시각이 없다(수집기의 five_hour 창)
            claudeSession = RateWindow(percent: 0, resetsAt: nil, windowMinutes: 300)
            claudeWeekly = RateWindow(percent: 100, resetsAt: blockedWeeklyReset, windowMinutes: 10_080)
        }
        if staleClaude {
            // 묵은 스냅샷 + 리셋 시각 없는 세션 = 값 미상. 주간은 리셋 시각을 알아 흐린 숫자로 남는다
            claudeSession = RateWindow(percent: claudeSession.percent, resetsAt: nil, windowMinutes: 300)
            claudeCollectedAt = at(-3 * 86400)
        }

        let claude = Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: claudeSession,
            weekly: claudeWeekly,
            extras: [ExtraWindow(
                name: "Fable weekly",
                window: RateWindow(percent: 41, resetsAt: at(2.8 * 86400), windowMinutes: 10_080)
            )],
            status: ProviderStatus(indicator: "none", description: nil),
            account: "demo-claude",
            deviceLabel: "Demo-MacBookPro.local",
            // 수집 시각, 수집 상태까지 채운다, 비워두면 앱은 "상태 미상", 위젯은 낡은 스냅샷으로 그린다
            collectedAt: claudeCollectedAt
        )
        let codex = Provider(
            id: "codex",
            name: "Codex",
            plan: "Pro",
            session: RateWindow(percent: 78, resetsAt: at(1.4 * 3600), windowMinutes: 300),
            weekly: RateWindow(percent: 51, resetsAt: at(4.1 * 86400), windowMinutes: 10_080),
            extras: nil,
            status: ProviderStatus(indicator: "none", description: nil),
            account: "demo-codex",
            deviceLabel: "Demo-MacBookPro.local",
            collectedAt: at(-90)
        )
        let gemini = Provider(
            id: "gemini",
            name: "Gemini",
            plan: "AI Pro",
            session: RateWindow(percent: 12, resetsAt: at(9.5 * 3600), windowMinutes: 1440, label: "Daily"),
            weekly: RateWindow(percent: 27, resetsAt: at(5.6 * 86400), windowMinutes: 10_080),
            extras: nil,
            status: ProviderStatus(indicator: "none", description: nil),
            account: "demo-gemini",
            deviceLabel: "Demo-MacBookPro.local",
            collectedAt: at(-90)
        )

        // 진행 중인 5시간 블록: 1.8시간 경과, $6.42 사용
        let live = ActiveBlock(
            costUSD: 6.42,
            totalTokens: 2_140_000,
            startTime: at(-1.8 * 3600),
            endTime: at(3.2 * 3600),
            models: nil,
            burnRate: ActiveBlock.BurnRate(costPerHour: 3.57),
            projection: ActiveBlock.Projection(remainingMinutes: 192, totalCost: 17.85)
        )
        // 한도에 막혀 있는 동안에는 Claude Code 5시간 블록도 생기지 않는다
        let liveBlock: ActiveBlock? = quotaProtection ? nil : live

        // 스트릭 보호 픽스처의 차단 구간. 그저께 밤부터 막혀 어제와 오늘을 모두 자정 전부터 덮고,
        // 리셋은 내일 이후라 오늘 하루 전체를 덮는다. 보호 판정(ContentView)과 같은 달력을 쓴다.
        var quotaBlocks: [QuotaBlock]? = nil
        if quotaProtection {
            let calendar = Calendar.current
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
            quotaBlocks = [QuotaBlock(
                providerId: "claude",
                account: "demo-claude",
                windowKind: "weekly",
                resetAt: blockedWeeklyReset,
                observedAccounts: ["demo-claude"],
                firstSeenAt: iso.string(from: startOfYesterday.addingTimeInterval(-3 * 3600)),
                lastSeenAt: at(-90),
                clearedAt: nil
            )]
        }

        var device = CollectorDevice(
            id: "demo-device",
            label: "Demo-MacBookPro.local",
            lastSeenAt: at(-90),
            collectStatus: ["claude": "ok", "codex": "ok", "gemini": "ok"],
            // 버전을 비우면 설정 화면에 수집기 업데이트 안내가 떠 심사, 스크린샷에 그대로 찍힌다
            collectorVersion: "0.2.0"
        )
        // Deterministic recovery fixtures, scoped to demo mode and this process.
        if let i = args.firstIndex(of: "-charge-demo-collection-failures"),
           args.indices.contains(i + 1), let count = Int(args[i + 1]), count > 0 {
            let reasonIndex = args.firstIndex(of: "-charge-demo-collection-reason")
            let reason = reasonIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                ?? "error:access_denied"
            let since = Int(now.addingTimeInterval(-90 - 20 * 60).timeIntervalSince1970)
            device.collectStatus?["claude"] = "\(reason);failures=\(count);since=\(since)"
        }
        var devices = [device]
        if args.contains("-charge-demo-second-device") || args.contains("-charge-demo-healthy-second-device") {
            var secondStatus = device.collectStatus
            if args.contains("-charge-demo-healthy-second-device") { secondStatus?["claude"] = "ok" }
            devices.append(CollectorDevice(id: "demo-second", label: "Demo-MacMini.local",
                                           lastSeenAt: at(-90), collectStatus: secondStatus,
                                           collectorVersion: "0.2.0"))
        }

        return UsagePayload(
            generatedAt: at(-90),
            daily: dailyHistory(now: now, claudeBlockedDays: quotaProtection ? 2 : 0),
            live: liveBlock,
            liveBlocks: liveBlock.map { block in
                [DeviceActiveBlock(
                    deviceId: device.id,
                    deviceLabel: device.shortLabel,
                    block: block,
                    collectedAt: at(-90)
                )]
            } ?? [],
            providers: args.contains("-charge-demo-no-claude-card") ? [codex, gemini] : [claude, codex, gemini],
            devices: devices,
            quotaBlocks: quotaBlocks
        )
    }

    /// 스트릭 그리드(10주 = 70일)를 꽉 채우는 일별 사용량 — 주중이 높고 주말이 낮은 패턴.
    /// 난수 대신 날짜 기반 결정적 값이라 스크린샷·심사 때마다 모양이 같다.
    /// claudeBlockedDays: 오늘부터 거슬러 이 일수만큼은 Claude 모델 사용이 없다(스트릭 보호 픽스처).
    private static func dailyHistory(now: Date, claudeBlockedDays: Int = 0) -> [DailyUsage] {
        let calendar = Calendar(identifier: .gregorian)
        let days = ChargeDate.streakWeeks * 7
        return (0..<days).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            let isWeekend = weekday == 1 || weekday == 7
            // 날짜 기반 유사 난수 (0..<1) — 실행할 때마다 같은 곡선
            let noise = Double((back * 2_654_435_761) % 1000) / 1000
            var cost = (isWeekend ? 6.0 : 22.0) + noise * (isWeekend ? 9 : 26)
            // 최근 2주는 확실히 활동이 있게 (스트릭·차트가 살아 보이도록), 그 전엔 가끔 쉰 날
            if back > 14, noise > 0.87 { cost = 0 }
            if back == 0 { cost = 18.7 }  // 오늘: 진행 중인 값

            func model(_ name: String, _ cost: Double, cached: Bool = true) -> ModelBreakdown {
                ModelBreakdown(modelName: name, cost: cost,
                               inputTokens: Int(cost * 9_000), outputTokens: Int(cost * 2_700),
                               cacheCreationTokens: cached ? Int(cost * 12_000) : nil,
                               cacheReadTokens: cached ? Int(cost * 45_000) : nil)
            }
            var models = cost <= 0 ? [] : [
                model("claude-fable-5", cost * 0.43),
                model("claude-opus-5", cost * 0.19),
                model("gpt-5.4-codex", cost * 0.27, cached: false),
                model("gemini-3-pro", cost * 0.11, cached: false),
            ]
            // 한도에 막힌 날에는 Claude를 쓰지 못했다. 다른 프로바이더 사용은 그대로 둬
            // 전체 스트릭과 Codex, Gemini 스트릭은 이어진다.
            if back < claudeBlockedDays {
                models.removeAll { providerId(forModel: $0.modelName) == "claude" }
                cost = models.reduce(0) { $0 + $1.cost }
            }
            let tokens = Int(cost * 118_000)
            return DailyUsage(
                period: ChargeDate.day.string(from: date),
                totalCost: cost,
                totalTokens: tokens,
                inputTokens: Int(Double(tokens) * 0.08),
                outputTokens: Int(Double(tokens) * 0.03),
                cacheReadTokens: Int(Double(tokens) * 0.74),
                cacheCreationTokens: Int(Double(tokens) * 0.15),
                models: models
            )
        }
    }
}
