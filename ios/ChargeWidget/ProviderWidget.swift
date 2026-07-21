import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 위젯 설정 (프로바이더 선택)

enum ProviderChoice: String, AppEnum {
    case all, claude, codex

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .all: "All",
        .claude: "Claude",
        .codex: "Codex",
    ]
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Provider"
    static var description = IntentDescription("Pick which AI provider to show.")

    @Parameter(title: "Provider", default: .all)
    var provider: ProviderChoice
}

// MARK: - 타임라인

struct ProviderEntry: TimelineEntry {
    let date: Date
    let providers: [Provider]
}

struct ProviderTimelineProvider: AppIntentTimelineProvider {
    private var sample: [Provider] {
        [
            Provider(id: "claude", name: "Claude",
                     session: RateWindow(percent: 34, resetsAt: nil),
                     weekly: RateWindow(percent: 62, resetsAt: nil),
                     extras: nil, status: nil),
            Provider(id: "codex", name: "Codex",
                     session: RateWindow(percent: 78, resetsAt: nil),
                     weekly: RateWindow(percent: 51, resetsAt: nil),
                     extras: nil, status: nil),
        ]
    }

    func placeholder(in context: Context) -> ProviderEntry {
        ProviderEntry(date: .now, providers: sample)
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ProviderEntry {
        placeholder(in: context)
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        var chosen: [Provider] = []
        if let all = await ChargeAPI.fetchAllOrCached()?.providers, !all.isEmpty {
            let visible = all.filter { !ChargeConfig.isHidden($0.id) }
            switch configuration.provider {
            case .all: chosen = visible
            default: chosen = visible.filter { $0.id == configuration.provider.rawValue }
            }
        }
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        return Timeline(entries: [ProviderEntry(date: .now, providers: chosen)], policy: .after(next))
    }
}

// MARK: - 공용 뷰

private func gaugeTint(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 70 ? .orange : ChargeTheme.accent
}

struct ProviderBar: View {
    let title: LocalizedStringKey
    let window: RateWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let w = window {
                    Text("\(Int(w.percent))%")
                        .font(.caption2.monospacedDigit().bold())
                }
            }
            ProgressView(value: min(window?.percent ?? 0, 100), total: 100)
                .tint(gaugeTint(window?.percent ?? 0))
        }
    }
}

/// 한 프로바이더의 세션/주간 바 묶음
struct ProviderColumn: View {
    let provider: Provider
    var showReset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.name).font(.subheadline.bold())
                Spacer()
                if showReset, let reset = provider.session?.resetShort {
                    Text(reset).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ProviderBar(title: "Session", window: provider.session)
            ProviderBar(title: "Weekly", window: provider.weekly)
        }
    }
}

// MARK: - 패밀리별 뷰

struct ProviderWidgetView: View {
    var entry: ProviderEntry
    @Environment(\.widgetFamily) private var family

    /// 원형 위젯처럼 하나만 보여줘야 할 때: 사용률 높은(급한) 프로바이더 우선
    private var mostUrgent: Provider? {
        entry.providers.max { ($0.session?.percent ?? 0) < ($1.session?.percent ?? 0) }
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circularView
        case .accessoryRectangular: rectangularView
        case .systemMedium: mediumView
        default: smallView
        }
    }

    /// 홈 스몰: 1개면 여유 있게, 여러 개면 컴팩트하게 세로 적층
    private var smallView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.providers.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.providers) { p in
                ProviderColumn(provider: p, showReset: entry.providers.count == 1)
            }
        }
        .containerBackground(for: .widget) { ChargeTheme.background }
        .environment(\.colorScheme, .dark)
    }

    /// 홈 미디엄: 프로바이더를 좌우 열로 나란히
    private var mediumView: some View {
        HStack(alignment: .top, spacing: 16) {
            if entry.providers.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.providers) { p in
                ProviderColumn(provider: p)
            }
        }
        .containerBackground(for: .widget) { ChargeTheme.background }
        .environment(\.colorScheme, .dark)
    }

    /// 잠금화면 1x1: 고리형 게이지 (가장 급한 프로바이더의 세션 %)
    private var circularView: some View {
        Gauge(value: min(mostUrgent?.session?.percent ?? 0, 100), in: 0...100) {
            Text(String((mostUrgent?.name ?? "—").prefix(2)))
        } currentValueLabel: {
            Text("\(Int(mostUrgent?.session?.percent ?? 0))%")
                .font(.system(.body, design: .rounded).bold())
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 잠금화면 1x2: 프로바이더당 한 줄 (이름 + 세션/주간 %)
    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.providers.isEmpty {
                Text("No data").font(.caption2)
            }
            ForEach(entry.providers.prefix(3)) { p in
                HStack(spacing: 6) {
                    Text(p.name).font(.caption.bold())
                    Spacer()
                    Text("S \(Int(p.session?.percent ?? 0))%")
                        .font(.caption2.monospacedDigit())
                    Text("W \(Int(p.weekly?.percent ?? 0))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - 위젯 정의

struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ProviderWidget",
                               intent: SelectProviderIntent.self,
                               provider: ProviderTimelineProvider()) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Provider Gauges")
        .description("Session and weekly usage per provider. Long-press to choose one.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
