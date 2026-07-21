import SwiftUI
import Charts

struct ContentView: View {
    @State private var daily: [DailyUsage] = []
    @State private var live: ActiveBlock?
    @State private var providers: [Provider] = []
    @State private var generatedAt: Date?
    @State private var error: String?
    @State private var loading = false
    @State private var segment = "all"
    @State private var showSettings = false
    @State private var hidden: Set<String> = []
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14

    /// 세그먼트 선택에 따른 프로바이더 필터 (nil = 전체)
    private var pid: String? { segment == "all" ? nil : segment }

    private var updatedText: String? {
        guard let d = generatedAt else { return nil }
        let min = max(0, Int(-d.timeIntervalSinceNow) / 60)
        return min == 0
            ? String(localized: "Updated just now")
            : String(localized: "Updated \(min)m ago")
    }

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
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hidden = ChargeConfig.hiddenProviders
                Task { await load() }
            }) {
                SettingsView(generatedAt: generatedAt, providers: providers)
            }
            .refreshable { await load() }
            .task {
                hidden = ChargeConfig.hiddenProviders
                await load()
            }
        }
        .preferredColorScheme(.dark)
        .tint(ChargeTheme.accent)
    }

    private var content: some View {
        VStack(spacing: 16) {
            if let updatedText {
                Text(updatedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleProviders.count > 1 {
                Picker("Provider", selection: $segment) {
                    Text("All").tag("all")
                    ForEach(visibleProviders) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            todayCard
            ForEach(visibleProviders.filter { pid == nil || $0.id == pid }) { providerCard($0) }
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
        let weeks = 10
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

    private func providerCard(_ p: Provider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name)
                    .font(.headline)
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
            if let s = p.session, !s.isStale {
                gaugeRow(title: "Session", window: s)
            }
            if let w = p.weekly, !w.isStale {
                gaugeRow(title: "Weekly", window: w)
            }
            ForEach((p.extras ?? []).filter { !$0.window.isStale }) { e in
                gaugeRow(title: "\(e.name) weekly", window: e.window)
            }
        }
        .cardStyle()
    }

    private func gaugeRow(title: LocalizedStringKey, window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = window.resetText {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(window.percent, 100), total: 100)
                .tint(window.percent >= critThreshold ? .red : window.percent >= warnThreshold ? .orange : .green)
            HStack(spacing: 3) {
                Text("\(Int(window.percent))%")
                    .font(.caption.monospacedDigit())
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if window.percent >= 100 {
                    Text("Limit reached")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if let eta = window.projectedExhaustion {
                    Text("⚡ On pace to run out in \(paceShort(eta))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
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

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let payload = try await ChargeAPI.fetchAll()
            daily = payload.daily
            live = payload.live
            providers = payload.providers ?? []
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
        } catch ChargeError.notConfigured {
            self.error = String(localized: "Set your Gist URL in Settings (top right).")
        } catch {
            self.error = String(localized: "Failed to load: \(error.localizedDescription)")
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
