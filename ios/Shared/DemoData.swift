import Foundation

/// 데모 모드 샘플 데이터 — 네트워크·로그인 없이 앱·위젯의 모든 UI를 채운다.
/// (App Store 심사원이 수집기 없이 앱을 평가할 수 있어야 하고,
///  위젯 갤러리 프리뷰도 같은 데이터를 쓴다 — 픽스처의 정본은 이 파일 하나다)
enum DemoData {
    /// 프로세스당 1회 생성해 고정한다 — resetsAt이 호출마다 바뀌면 위젯 지문이 매번 달라져
    /// 60초 폴링이 내용 변화 없이도 reloadAllTimelines를 반복하게 된다.
    /// 카운트다운 표시는 어차피 뷰(TimelineView)가 현재 시각 기준으로 그린다.
    static let payload: UsagePayload = make()

    private static let iso = ISO8601DateFormatter()

    private static func make(now: Date = Date()) -> UsagePayload {
        func at(_ seconds: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(seconds)) }

        // 세션 창: 5시간 중 3시간 경과(60%), 주간 창: 7일 중 4.2일 경과
        let claude = Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: RateWindow(percent: 34, resetsAt: at(2 * 3600), windowMinutes: 300),
            weekly: RateWindow(percent: 62, resetsAt: at(2.8 * 86400), windowMinutes: 10_080),
            extras: [ExtraWindow(
                name: "Fable weekly",
                window: RateWindow(percent: 41, resetsAt: at(2.8 * 86400), windowMinutes: 10_080)
            )],
            status: ProviderStatus(indicator: "none", description: nil),
            account: "demo-claude",
            deviceLabel: "Demo-MacBookPro.local"
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
            deviceLabel: "Demo-MacBookPro.local"
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
            deviceLabel: "Demo-MacBookPro.local"
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

        let device = CollectorDevice(
            id: "demo-device",
            label: "Demo-MacBookPro.local",
            lastSeenAt: at(-90)
        )

        return UsagePayload(
            generatedAt: at(-90),
            daily: dailyHistory(now: now),
            live: live,
            providers: [claude, codex, gemini],
            devices: [device]
        )
    }

    /// 스트릭 그리드(10주 = 70일)를 꽉 채우는 일별 사용량 — 주중이 높고 주말이 낮은 패턴.
    /// 난수 대신 날짜 기반 결정적 값이라 스크린샷·심사 때마다 모양이 같다.
    private static func dailyHistory(now: Date) -> [DailyUsage] {
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
            let models = cost <= 0 ? [] : [
                model("claude-fable-5", cost * 0.43),
                model("claude-opus-5", cost * 0.19),
                model("gpt-5.4-codex", cost * 0.27, cached: false),
                model("gemini-3-pro", cost * 0.11, cached: false),
            ]
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
