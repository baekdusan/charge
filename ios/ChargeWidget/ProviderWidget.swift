import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget configuration

enum ProviderChoice: String, AppEnum {
    case all, claude, codex

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .all: "All",
        .claude: "Claude",
        .codex: "Codex",
    ]
}

enum ProviderWidgetStyle {
    case gauge
    case number
    case bars
    case summary
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Provider"
    static var description = IntentDescription("Pick which AI provider to show.")

    @Parameter(title: "Provider", default: .all)
    var provider: ProviderChoice
}

struct SelectLockProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Provider"
    static var description = IntentDescription("Pick which AI provider to show.")

    @Parameter(title: "Provider", default: .all)
    var provider: ProviderChoice
}

// MARK: - Timeline

struct ProviderEntry: TimelineEntry {
    let date: Date
    let providers: [Provider]
    fileprivate let style: ProviderWidgetStyle
}

private func sampleWindow(percent: Double, minutes: Int, elapsed: Double) -> RateWindow {
    let remaining = Double(minutes) * 60 * (1 - elapsed)
    return RateWindow(
        percent: percent,
        resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(remaining)),
        windowMinutes: minutes
    )
}

private var sampleProviders: [Provider] {
    [
        Provider(
            id: "claude",
            name: "Claude",
            plan: "Max 20x",
            session: sampleWindow(percent: 34, minutes: 300, elapsed: 0.61),
            weekly: sampleWindow(percent: 62, minutes: 10_080, elapsed: 0.42),
            extras: nil,
            status: nil
        ),
        Provider(
            id: "codex",
            name: "Codex",
            plan: "Education",
            session: sampleWindow(percent: 78, minutes: 300, elapsed: 0.48),
            weekly: sampleWindow(percent: 51, minutes: 10_080, elapsed: 0.76),
            extras: nil,
            status: nil
        ),
    ]
}

private func selectedProviders(_ providers: [Provider], choice: ProviderChoice) -> [Provider] {
    let visible = providers.filter { !ChargeConfig.isHidden($0.id) }
    switch choice {
    case .all:
        return visible
    default:
        return visible.filter { $0.id == choice.rawValue }
    }
}

private func loadProviders(choice: ProviderChoice) async -> [Provider] {
    guard let providers = await ChargeAPI.fetchAllOrCached()?.providers else { return [] }
    return selectedProviders(providers, choice: choice)
}

private func providerTimeline(choice: ProviderChoice, style: ProviderWidgetStyle) async -> Timeline<ProviderEntry> {
    let providers = await loadProviders(choice: choice)
    let entry = ProviderEntry(date: .now, providers: providers, style: style)
    return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60)))
}

struct ProviderTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProviderEntry {
        ProviderEntry(date: .now, providers: sampleProviders, style: .bars)
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ProviderEntry {
        ProviderEntry(
            date: .now,
            providers: selectedProviders(sampleProviders, choice: configuration.provider),
            style: .bars
        )
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        await providerTimeline(choice: configuration.provider, style: .bars)
    }
}

struct LockProviderTimelineProvider: AppIntentTimelineProvider {
    let style: ProviderWidgetStyle

    func placeholder(in context: Context) -> ProviderEntry {
        ProviderEntry(date: .now, providers: sampleProviders, style: style)
    }

    func snapshot(for configuration: SelectLockProviderIntent, in context: Context) async -> ProviderEntry {
        ProviderEntry(
            date: .now,
            providers: selectedProviders(sampleProviders, choice: configuration.provider),
            style: style
        )
    }

    func timeline(for configuration: SelectLockProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        await providerTimeline(choice: configuration.provider, style: style)
    }
}

// MARK: - Shared views

private func gaugeTint(_ percent: Double) -> Color {
    percent >= 90 ? .red : percent >= 70 ? .orange : ChargeTheme.accent
}

private struct WidgetUsageGauge: View {
    let state: RateWindowDisplayState?
    let tint: Color
    let track: Color
    let marker: Color
    var barHeight: CGFloat = 4
    var markerHeight: CGFloat = 9

    var body: some View {
        let usage = min(1, max(0, (state?.window.percent ?? 0) / 100))
        let timeProgress = state?.window.timeProgress
        let isEstimated = state?.isEstimated == true

        GeometryReader { geometry in
            ZStack {
                Capsule()
                    .fill(track)
                    .frame(height: barHeight)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * usage, height: barHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let timeProgress {
                    let markerWidth = 2.0
                    let markerCenter = min(
                        geometry.size.width - markerWidth / 2,
                        max(markerWidth / 2, geometry.size.width * timeProgress)
                    )
                    RoundedRectangle(cornerRadius: 1)
                        .fill(marker)
                        .frame(width: markerWidth, height: markerHeight)
                        .position(x: markerCenter, y: geometry.size.height / 2)
                }
            }
        }
        .frame(height: markerHeight)
        .opacity(isEstimated ? 0.55 : 1)
        .blur(radius: isEstimated ? 0.35 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue("\(Int(state?.window.percent ?? 0)) percent")
    }
}

private struct ProviderBar: View {
    let title: LocalizedStringKey
    let window: RateWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = window?.displayState(at: context.date)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let state {
                        Text("\(Int(state.window.percent))%")
                            .font(.caption2.monospacedDigit().bold())
                    }
                }
                WidgetUsageGauge(
                    state: state,
                    tint: gaugeTint(state?.window.percent ?? 0),
                    track: .white.opacity(0.14),
                    marker: .white.opacity(0.92)
                )
            }
            .opacity(state?.isEstimated == true ? 0.62 : 1)
        }
    }
}

private struct ProviderColumn: View {
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            ProviderBar(title: "Session", window: provider.session)
            ProviderBar(title: "Weekly", window: provider.weekly)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Family views

struct ProviderWidgetView: View {
    var entry: ProviderEntry
    @Environment(\.widgetFamily) private var family

    private var mostUrgent: Provider? {
        entry.providers.max {
            ($0.session?.displayState()?.window.percent ?? 0)
                < ($1.session?.displayState()?.window.percent ?? 0)
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    private var smallView: some View {
        let providers = Array(entry.providers.prefix(2))

        return VStack(alignment: .leading, spacing: 7) {
            if providers.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers, id: \.uid) { provider in
                    ProviderColumn(provider: provider)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { ChargeTheme.background }
        .environment(\.colorScheme, .dark)
    }

    private var mediumView: some View {
        let providers = Array(entry.providers.prefix(2))

        return HStack(alignment: .top, spacing: 16) {
            if providers.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers, id: \.uid) { provider in
                    ProviderColumn(provider: provider)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { ChargeTheme.background }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var circularView: some View {
        let state = mostUrgent?.session?.displayState()
        let percent = Int(state?.window.percent ?? 0)
        let estimatePrefix = state?.isEstimated == true ? "~" : ""

        switch entry.style {
        case .number:
            VStack(spacing: 0) {
                Text(String((mostUrgent?.name ?? "-").prefix(6)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(estimatePrefix)\(percent)%")
                    .font(.system(.title3, design: .rounded).bold())
                    .minimumScaleFactor(0.55)
            }
            .opacity(state?.isEstimated == true ? 0.58 : 1)
            .containerBackground(.fill.tertiary, for: .widget)
        default:
            Gauge(value: min(state?.window.percent ?? 0, 100), in: 0...100) {
                Text(String((mostUrgent?.name ?? "-").prefix(2)))
            } currentValueLabel: {
                Text("\(estimatePrefix)\(percent)%")
                    .font(.system(.body, design: .rounded).bold())
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircular)
            .opacity(state?.isEstimated == true ? 0.58 : 1)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    @ViewBuilder
    private var rectangularView: some View {
        switch entry.style {
        case .bars:
            lockBarsView
        default:
            lockSummaryView
        }
    }

    private var lockBarsView: some View {
        VStack(alignment: .leading, spacing: 5) {
            if entry.providers.isEmpty {
                Text("No data").font(.caption2)
            } else {
                ForEach(entry.providers.prefix(2), id: \.uid) { provider in
                    let state = provider.session?.displayState()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(provider.name)
                                .font(.caption2.bold())
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(state?.window.percent ?? 0))%")
                                .font(.caption2.monospacedDigit())
                        }
                        WidgetUsageGauge(
                            state: state,
                            tint: .primary,
                            track: .primary.opacity(0.22),
                            marker: .primary,
                            barHeight: 3,
                            markerHeight: 8
                        )
                    }
                    .opacity(state?.isEstimated == true ? 0.58 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var lockSummaryView: some View {
        let provider = mostUrgent
        let session = provider?.session?.displayState()
        let weekly = provider?.weekly?.displayState()

        return VStack(alignment: .leading, spacing: 2) {
            if let provider {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(provider.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    if let plan = provider.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("S")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(session?.window.percent ?? 0))%")
                        .font(.system(.title3, design: .rounded).bold().monospacedDigit())
                        .opacity(session?.isEstimated == true ? 0.58 : 1)
                    Spacer(minLength: 8)
                    Text("W")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(weekly?.window.percent ?? 0))%")
                        .font(.system(.title3, design: .rounded).bold().monospacedDigit())
                        .opacity(weekly?.isEstimated == true ? 0.58 : 1)
                }
            } else {
                Text("No data").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inlineView: some View {
        Text(
            entry.providers.isEmpty
                ? String(localized: "No data")
                : entry.providers.prefix(2).map { provider in
                    let state = provider.session?.displayState()
                    let prefix = state?.isEstimated == true ? "~" : ""
                    return "\(provider.name) \(prefix)\(Int(state?.window.percent ?? 0))%"
                }.joined(separator: " | ")
        )
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget definitions

struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderWidget",
            intent: SelectProviderIntent.self,
            provider: ProviderTimelineProvider()
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Provider Usage")
        .description("Session and weekly usage with plan and time markers.")
        // 잠금화면 패밀리 유지: 예전 빌드에서 이 kind로 추가한 잠금화면 위젯이
        // 업데이트 후 무효화되지 않도록 한다 (신규 잠금화면 위젯은 전용 kind 사용)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ProviderRingLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderRingLockWidget",
            intent: SelectLockProviderIntent.self,
            provider: LockProviderTimelineProvider(style: .gauge)
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Limit Ring")
        .description("Session usage in a compact ring.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ProviderNumberLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderNumberLockWidget",
            intent: SelectLockProviderIntent.self,
            provider: LockProviderTimelineProvider(style: .number)
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Limit Number")
        .description("Session usage as a large percentage.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ProviderBarsLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderBarsLockWidget",
            intent: SelectLockProviderIntent.self,
            provider: LockProviderTimelineProvider(style: .bars)
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Bars")
        .description("Two provider gauges with time markers.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct ProviderSummaryLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderSummaryLockWidget",
            intent: SelectLockProviderIntent.self,
            provider: LockProviderTimelineProvider(style: .summary)
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Summary")
        .description("Session and weekly usage at a glance.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct ProviderInlineLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ProviderInlineLockWidget",
            intent: SelectLockProviderIntent.self,
            provider: LockProviderTimelineProvider(style: .number)
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Inline")
        .description("Provider usage beside the lock screen date.")
        .supportedFamilies([.accessoryInline])
    }
}
