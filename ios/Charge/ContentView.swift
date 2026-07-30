import SwiftUI
import Charts
import WidgetKit

struct ContentView: View {
    @State private var daily: [DailyUsage] = []
    @State private var live: ActiveBlock?
    @State private var providers: [Provider] = []
    @State private var devices: [CollectorDevice] = []
    @State private var generatedAt: Date?
    @State private var error: String?
    @State private var loading = false
    @State private var segment = "all"
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var hidden: Set<String> = []
    /// 현재 providers/devices 페이로드를 조회하기 시작한 시점의 세션 세대
    @State private var payloadEpoch = ChargeAuth.sessionEpoch
    /// 위젯에 마지막으로 반영한 "표시 콘텐츠" 지문 — 실제 값이 바뀔 때만 위젯을 리로드한다
    @State private var lastWidgetSync: String?
    /// 백그라운드를 거쳐 돌아왔는지 — 최초 실행 시의 불필요한 재로드를 막는다
    @State private var wasBackgrounded = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14

    /// 세그먼트 선택에 따른 프로바이더 필터 (nil = 전체)
    private var pid: String? { segment == "all" ? nil : segment }

    private var today: DailyUsage? {
        daily.first { $0.period == ChargeDate.todayString() }
    }

    private var weekCost: Double {
        daily.suffix(7).reduce(0) { $0 + $1.cost(for: pid) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
            }
            .background(ChargeTheme.background.ignoresSafeArea())
            .navigationTitle("Charge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hidden = ChargeConfig.hiddenProviders
                Task { await load(reloadWidgets: true) }
            }) {
                SettingsView(generatedAt: generatedAt, providers: providers, devices: devices,
                             snapshotEpoch: payloadEpoch)
            }
            // 손을 일찍 떼면 SwiftUI가 refreshable 태스크를 취소하므로,
            // 분리된 태스크로 실행해 실제 로드가 중간에 끊기지 않게 한다
            .refreshable { await Task { await load(reloadWidgets: true) }.value }
            .task {
                hidden = ChargeConfig.hiddenProviders
                if !ChargeAuth.hasUsableData {
                    showOnboarding = true
                }
                await load(reloadWidgets: true)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        break
                    }
                    if ChargeAuth.hasUsableData {
                        await load()
                    } else if !showOnboarding {
                        // 위젯 프로세스가 무효 세션을 감지해 로그아웃했을 수 있다 —
                        // 앱도 이전 계정 데이터를 지우고 로그인 화면으로 유도한다
                        daily = []
                        live = nil
                        providers = []
                        devices = []
                        generatedAt = nil
                        error = String(localized: "Sign in to see your usage.")
                        showOnboarding = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                // 첫 실행/재로그인: 이미 연결된 기기가 있으면 새 페어링 없이 바로 통과
                OnboardingView(requiresNewDevice: false) {
                    showOnboarding = false
                    // 로그아웃이 공유 저장소의 숨김 목록을 비웠으므로 로컬 상태도 다시 읽는다 —
                    // 안 그러면 이전 계정에서 숨긴 id가 새 계정에서도 계속 숨는다
                    hidden = ChargeConfig.hiddenProviders
                    Task { await load(reloadWidgets: true) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where wasBackgrounded:
                // 백그라운드에서 돌아옴 — 최신 데이터로 새로고침하고 위젯도 맞춘다
                wasBackgrounded = false
                Task { await load(reloadWidgets: true) }
            case .background:
                // 앱을 나가기 직전 위젯이 최신 데이터로 타임라인을 다시 만들게 한다
                // (홈·잠금화면 위젯이 곧바로 최신값을 보이도록)
                wasBackgrounded = true
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }

    private var content: some View {
        let duplicates = duplicateProviderIds
        return VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                connectionStatus(at: context.date)
            }
            if segmentProviders.count > 1 {
                Picker("Provider", selection: $segment) {
                    Text("All").tag("all")
                    ForEach(segmentProviders) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            todayCard
            ForEach(visibleProviders.filter { pid == nil || $0.id == pid }, id: \.uid) {
                providerCard($0, duplicates: duplicates)
            }
            if let live, pid == nil || pid == "claude" { liveCard(live) }
            streakCard
            chartCard
            if let today, !today.mergedModels.isEmpty {
                modelCard(today)
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(fmtUSD(today?.cost(for: pid) ?? 0))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(fmtTokens(today?.tokens(for: pid) ?? 0)) tokens")
                    Text("7d \(fmtUSD(weekCost))")
                    Text("30d \(fmtUSD(daily.suffix(30).reduce(0) { $0 + $1.cost(for: pid) }))")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func todayCost(of p: Provider) -> Double {
        today?.cost(for: p.id) ?? 0
    }

    private var visibleProviders: [Provider] {
        providers.filter { !hidden.contains($0.id) }
    }

    /// 같은 프로바이더가 계정별 카드로 2개 이상인 id 집합 — 카드마다 전체를 재스캔하지 않게 한 번만 계산
    private var duplicateProviderIds: Set<String> {
        var seen = Set<String>()
        var dups = Set<String>()
        for p in visibleProviders where !seen.insert(p.id).inserted { dups.insert(p.id) }
        return dups
    }

    /// 세그먼트용: 같은 프로바이더의 계정별 카드가 여러 개여도 세그먼트는 하나만
    private var segmentProviders: [Provider] {
        var seen = Set<String>()
        return visibleProviders.filter { seen.insert($0.id).inserted }
    }

    /// last_seen이 갱신될 때마다 행이 뒤바뀌지 않게 이름 기준 고정 정렬
    private var sortedDevices: [CollectorDevice] {
        devices.sorted { ($0.shortLabel ?? "", $0.id) < ($1.shortLabel ?? "", $1.id) }
    }

    private func connectionStatus(at now: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if devices.isEmpty {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 9, height: 9)
                        Text(loading ? "Checking PC connection" : "No PC paired")
                            .font(.caption.weight(.semibold))
                    }
                } else {
                    ForEach(sortedDevices) { device in
                        deviceStatusRow(device, at: now)
                    }
                }
            }
            Spacer(minLength: 8)
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func deviceStatusRow(_ device: CollectorDevice, at now: Date) -> some View {
        let isTracking = device.isTracking(at: now)
        let displayName = device.shortLabel ?? String(localized: "Linked PC")
        return HStack(spacing: 10) {
            Circle()
                .fill(isTracking ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(isTracking ? "PC tracking active" : "Waiting for PC")
                    .font(.caption.weight(.semibold))
                if let lastSeen = device.lastSeenDate {
                    let relative = lastSeen.formatted(
                        .relative(presentation: .numeric, unitsStyle: .abbreviated)
                    )
                    Text(verbatim: "\(displayName) · \(relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: 스트릭 (잔디)

    private func streak(for pid: String?) -> Int {
        let costByDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.period, $0.cost(for: pid)) })
        var count = 0
        var cursor = Date()
        // 오늘 기록이 없으면 어제부터 센다
        if (costByDay[ChargeDate.day.string(from: cursor)] ?? 0) <= 0 {
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        while (costByDay[ChargeDate.day.string(from: cursor)] ?? 0) > 0 {
            count += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }

    private var streakCard: some View {
        let f = ChargeDate.day
        let costByDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.period, $0.cost(for: pid)) })
        let weeks = ChargeDate.streakWeeks
        let start = Calendar.current.date(byAdding: .day, value: -(weeks * 7 - 1), to: Date())!
        let maxCost = max(costByDay.values.max() ?? 0, 0.01)
        let todayRatio = (today?.cost(for: pid) ?? 0) / maxCost

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Streak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("🔥 \(streak(for: pid)) day streak")
                    .font(.caption.bold())
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<weeks, id: \.self) { col in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let date = Calendar.current.date(byAdding: .day, value: col * 7 + row, to: start)!
                            let cost = costByDay[f.string(from: date)] ?? 0
                            let future = date > Date()
                            RoundedRectangle(cornerRadius: 3)
                                .fill(future ? .clear
                                      : cost <= 0 ? Color.white.opacity(0.07)
                                      : ChargeTheme.accent.opacity(max(0.18, cost / maxCost)))
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            if (today?.cost(for: pid) ?? 0) > 0 {
                Text(String(format: String(localized: "today_peak_ratio"), Int(min(todayRatio, 1) * 100)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func providerCard(_ p: Provider, duplicates: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    ProviderGlyph(providerId: p.id, name: p.name)
                        .frame(width: 15, height: 15)
                    Text(p.name)
                        .font(.headline)
                }
                if let plan = p.plan {
                    Text(plan)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(ChargeTheme.accent)
                        .background(ChargeTheme.accent.opacity(0.15), in: Capsule())
                }
                if duplicates.contains(p.id), let device = p.deviceShortLabel {
                    Label(device, systemImage: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let st = p.status, !st.isHealthy {
                    Circle()
                        .fill(st.indicator == "critical" ? .red : st.indicator == "major" ? .orange : .yellow)
                        .frame(width: 8, height: 8)
                }
                Spacer()
                let cost = todayCost(of: p)
                if cost > 0 {
                    Text("Today \(fmtUSD(cost))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let st = p.status, !st.isHealthy, let desc = st.description {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let state = p.session?.displayState() {
                gaugeRow(title: p.session?.label ?? String(localized: "Session"), state: state)
            }
            if let state = p.weekly?.displayState() {
                gaugeRow(title: p.weekly?.label ?? String(localized: "Weekly"), state: state)
            }
            ForEach(p.extras ?? []) { e in
                if let state = e.window.displayState() {
                    gaugeRow(title: e.window.label ?? e.name, state: state)
                }
            }
        }
        .cardStyle()
    }

    private func gaugeRow(title: String, state: RateWindowDisplayState) -> some View {
        let window = state.window

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.isEstimated {
                    Label("Estimated", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let reset = window.resetText {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(state.isEstimated ? .tertiary : .secondary)
                }
            }
            if window.timeProgress != nil {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    usageGauge(window, isEstimated: state.isEstimated)
                }
            } else {
                usageGauge(window, isEstimated: state.isEstimated)
            }
            HStack(spacing: 3) {
                Text("\(Int(window.percent))%")
                    .font(.caption.monospacedDigit())
                if state.isEstimated {
                    Text("estimated")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !state.isEstimated, window.percent >= 100 {
                    Text("Limit reached")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if !state.isEstimated, let eta = window.projectedExhaustion {
                    Text("⚡ On pace to run out in \(paceShort(eta))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func usageGauge(_ window: RateWindow, isEstimated: Bool) -> some View {
        let usage = min(1, max(0, window.percent / 100))
        let timeProgress = window.timeProgress
        let tint: Color = window.percent >= critThreshold ? .red
            : window.percent >= warnThreshold ? .orange
            : .green

        return GeometryReader { geo in
            ZStack {
                Capsule()
                    .fill(.white.opacity(isEstimated ? 0.07 : 0.13))
                    .frame(height: 5)
                Capsule()
                    .fill(tint.opacity(isEstimated ? 0.45 : 1))
                    .frame(width: geo.size.width * usage, height: 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: isEstimated ? 0.45 : 0)
                if let timeProgress {
                    let markerWidth = 2.0
                    let markerCenter = min(
                        geo.size.width - markerWidth / 2,
                        max(markerWidth / 2, geo.size.width * timeProgress)
                    )
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(isEstimated ? 0.45 : 0.9))
                        .frame(width: markerWidth, height: 10)
                        .position(x: markerCenter, y: geo.size.height / 2)
                        .blur(radius: isEstimated ? 0.45 : 0)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isEstimated ? "Estimated usage" : "Usage")
        .accessibilityValue("\(Int(window.percent)) percent")
    }

    private func paceShort(_ d: Date) -> String {
        let sec = max(0, Int(d.timeIntervalSinceNow))
        let day = sec / 86400, h = (sec % 86400) / 3600, m = (sec % 3600) / 60
        if day > 0 { return "\(day)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func liveCard(_ block: ActiveBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Current 5h window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let end = block.end {
                    Text("Resets \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(fmtUSD(block.costUSD))
                    .font(.title2.bold())
                Spacer()
                if let rate = block.burnRate {
                    Text("\(fmtUSD(rate.costPerHour))/hr")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            ProgressView(value: block.windowProgress)
                .tint(.green)
            if let proj = block.projection {
                Text("Projected \(fmtUSD(proj.totalCost)) by window end")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost, last \(chartDays) days")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(daily.suffix(chartDays)) { day in
                BarMark(
                    x: .value("Date", day.date, unit: .day),
                    y: .value("Cost", day.cost(for: pid))
                )
                .foregroundStyle(.tint)
                .cornerRadius(3)
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
        }
        .cardStyle()
    }

    private func modelCard(_ day: DailyUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today by model")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(day.mergedModels.filter { pid == nil || providerId(forModel: $0.modelName) == pid }.prefix(5)) { m in
                HStack {
                    Text(m.modelName)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    Text(fmtUSD(m.cost))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    /// 위젯이 실제 렌더링하는 값만 추린 지문. 기기 last_seen_at·generatedAt처럼 매 사이클
    /// 변하는 값은 제외해, 표시 내용이 그대로면 불필요한 위젯 리로드를 하지 않는다.
    /// (generatedAt = charge_live 타임스탬프에만 의존하면 백엔드 ingest 방식에 결합되므로 사용하지 않는다.)
    private func widgetFingerprint(_ payload: UsagePayload) -> String {
        func win(_ w: RateWindow?) -> String {
            guard let w else { return "-" }
            return "\(w.percent):\(w.resetsAt ?? "")"
        }
        let provs = (payload.providers ?? [])
            .sorted { $0.uid < $1.uid }
            .map { p -> String in
                let extras = (p.extras ?? [])
                    .map { "\($0.name)=\(win($0.window))" }
                    .joined(separator: ",")
                return "\(p.uid)|\(p.plan ?? "")|\(p.status?.indicator ?? "")|S\(win(p.session))|W\(win(p.weekly))|E[\(extras)]"
            }
            .joined(separator: ";")
        let today = payload.daily.first { $0.period == ChargeDate.todayString() }?.totalCost ?? 0
        let live = payload.live?.costUSD ?? -1
        return "\(provs)#today:\(today)#live:\(live)"
    }

    private func load(reloadWidgets: Bool = false) async {
        // 이미 로드 중이면 끝날 때까지 기다렸다가 새로 로드한다 (풀 리프레시가 즉시 끝나 보이는 것 방지)
        while loading {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        loading = true
        defer { loading = false }
        do {
            // 로드 시작 시점의 세션 세대 — 로그아웃/재로그인을 건너온 응답인지 판별용
            let epoch = ChargeAuth.sessionEpoch
            let payload = try await ChargeAPI.fetchAll()
            daily = payload.daily
            live = payload.live
            // 사용자 순서는 데이터가 바뀔 때만 변한다 — 렌더마다가 아니라 로드 시 한 번 정렬
            // (설정 시트에서 순서를 바꾸면 onDismiss의 load()가 다시 반영한다)
            providers = ChargeConfig.sortedByUserOrder(payload.providers ?? [])
            devices = payload.devices ?? []
            payloadEpoch = epoch
            ChargeConfig.rememberProviders(providers)
            // 숨긴 프로바이더는 알림도 받지 않는다 — 설정 시트가 떠 있는 동안 이 뷰의
            // hidden 상태는 갱신되지 않으므로, 공유 저장소의 최신 숨김 목록으로 거른다.
            // (데모 모드 처리는 reschedule 내부에서 — 예약 대신 기존 알림까지 정리한다)
            ResetNotifications.reschedule(
                providers: providers.filter { !ChargeConfig.hiddenProviders.contains($0.id) },
                warnThreshold: warnThreshold,
                sessionEpoch: epoch
            )
            // 선택 중인 세그먼트가 숨겨졌거나 사라졌으면 전체로 복귀
            if let pid, !visibleProviders.contains(where: { $0.id == pid }) {
                segment = "all"
            }
            if let g = payload.generatedAt {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                generatedAt = f.date(from: g) ?? ISO8601DateFormatter().date(from: g)
            }
            error = nil
            // 위젯이 실제 보여주는 값이 바뀌었거나(60초 폴링 포함) 명시적 요청이면 리로드한다.
            // reloadAllTimelines()는 위젯 프로세스가 자기 타임라인을 다시 만들며 최신 데이터를 받아온다.
            let fingerprint = widgetFingerprint(payload)
            if reloadWidgets || fingerprint != lastWidgetSync {
                lastWidgetSync = fingerprint
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch ChargeError.notConfigured {
            // 로그아웃 상태 — 이전 계정 데이터를 화면에서 지우고 온보딩으로 유도
            daily = []
            live = nil
            providers = []
            devices = []
            generatedAt = nil
            self.error = String(localized: "Sign in to see your usage.")
            showOnboarding = true
        } catch is CancellationError {
            // 뷰 전환 등으로 취소된 로드 — 에러 아님
        } catch let e as URLError where e.code == .cancelled {
            // 위와 동일
        } catch {
            self.error = String(localized: "Failed to load: \(error.localizedDescription)")
            // 캐시가 무효화된 상태(기기 삭제 직후 등)라면 화면의 이전 스냅샷도 함께 비운다 —
            // 남겨두면 삭제된 컴퓨터의 사용량이 다음 성공 로드까지 계속 보인다
            if !ChargeAPI.hasCache {
                daily = []
                live = nil
                providers = []
                devices = []
                generatedAt = nil
            }
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(ChargeTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
