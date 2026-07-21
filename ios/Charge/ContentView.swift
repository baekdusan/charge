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
    @AppStorage("warnThreshold") private var warnThreshold = 70.0
    @AppStorage("critThreshold") private var critThreshold = 90.0
    @AppStorage("chartDays") private var chartDays = 14

    /// 세그먼트 선택에 따른 프로바이더 필터 (nil = 전체)
    private var pid: String? { segment == "all" ? nil : segment }

    private var updatedText: String? {
        guard let d = generatedAt else { return nil }
        let min = max(0, Int(-d.timeIntervalSinceNow) / 60)
        return min == 0 ? "방금 업데이트됨" : "\(min)분 전 업데이트됨"
    }

    private var today: DailyUsage? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return daily.first { $0.period == f.string(from: Date()) }
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
            .sheet(isPresented: $showSettings) {
                SettingsView(generatedAt: generatedAt)
            }
            .refreshable { await load() }
            .task { await load() }
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
            if providers.count > 1 {
                Picker("프로바이더", selection: $segment) {
                    Text("전체").tag("all")
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            todayCard
            ForEach(providers.filter { pid == nil || $0.id == pid }) { providerCard($0) }
            if let live, pid == nil || pid == "claude" { liveCard(live) }
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
            Text("오늘")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(fmtUSD(today?.cost(for: pid) ?? 0))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(fmtTokens(today?.tokens(for: pid) ?? 0)) tokens")
                    Text("7일 \(fmtUSD(weekCost))")
                    Text("30일 \(fmtUSD(daily.suffix(30).reduce(0) { $0 + $1.cost(for: pid) }))")
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
                    Text("오늘 \(fmtUSD(cost))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let st = p.status, !st.isHealthy, let desc = st.description {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let s = p.session {
                gaugeRow(title: "세션", window: s)
            }
            if let w = p.weekly {
                gaugeRow(title: "주간", window: w)
            }
            ForEach(p.extras ?? []) { e in
                gaugeRow(title: e.name, window: e.window)
            }
        }
        .cardStyle()
    }

    private func gaugeRow(title: String, window: RateWindow) -> some View {
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
            HStack {
                Text("\(Int(window.percent))% 사용")
                    .font(.caption.monospacedDigit())
                Spacer()
                if window.percent >= 100 {
                    Text("한도 도달")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if let eta = window.projectedExhaustion {
                    Text("⚡ 이 속도면 \(paceShort(eta)) 후 소진")
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
                Text("현재 5시간 창")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let end = block.end {
                    Text("리셋 \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(fmtUSD(block.costUSD))
                    .font(.title2.bold())
                Spacer()
                if let rate = block.burnRate {
                    Text("\(fmtUSD(rate.costPerHour))/시간")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            ProgressView(value: block.windowProgress)
                .tint(.green)
            if let proj = block.projection {
                Text("이 속도면 창 종료까지 총 \(fmtUSD(proj.totalCost)) 예상")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("최근 \(chartDays)일 비용")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(daily.suffix(chartDays)) { day in
                BarMark(
                    x: .value("날짜", day.date, unit: .day),
                    y: .value("비용", day.cost(for: pid))
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
            Text("오늘 모델별")
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
            if let g = payload.generatedAt {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                generatedAt = f.date(from: g) ?? ISO8601DateFormatter().date(from: g)
            }
            error = nil
        } catch {
            self.error = "불러오기 실패: \(error.localizedDescription)"
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
