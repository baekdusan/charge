import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget configuration

/// 위젯 설정용 프로바이더 항목 — 실제로 수집된(활성) 프로바이더만 선택지로 노출된다
struct ProviderEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var defaultQuery = ProviderEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProviderEntityQuery: EntityQuery {
    private func activeEntities() async -> [ProviderEntity] {
        let providers = await ChargeAPI.fetchAllOrCached()?.providers ?? []
        var seen = Set<String>()
        return providers.compactMap { p in
            seen.insert(p.id).inserted ? ProviderEntity(id: p.id, name: p.name) : nil
        }
    }

    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        let active = await activeEntities()
        return identifiers.map { id in
            active.first { $0.id == id } ?? ProviderEntity(id: id, name: id.capitalized)
        }
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        await activeEntities()
    }
}

enum ProviderWidgetStyle {
    case gauge
    case number
    case bars
    case summary
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Providers"
    static var description = IntentDescription("Pick which AI providers to show. Empty = all.")

    @Parameter(title: "Providers", default: [])
    var providers: [ProviderEntity]
}

struct SelectLockProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Providers"
    static var description = IntentDescription("Pick which AI providers to show. Empty = all.")

    @Parameter(title: "Providers", default: [])
    var providers: [ProviderEntity]
}

// MARK: - Timeline

struct ProviderEntry: TimelineEntry {
    let date: Date
    let providers: [Provider]
    fileprivate let style: ProviderWidgetStyle
}

/// 위젯 갤러리 프리뷰용 샘플 — 데모 모드와 같은 정본(DemoData)을 쓴다
private var sampleProviders: [Provider] { DemoData.payload.providers ?? [] }

private func selectedProviders(_ providers: [Provider], selection: [ProviderEntity]) -> [Provider] {
    // 앱 설정의 드래그 순서를 위젯에도 동일하게 적용한다 (숨김 목록은 한 번만 읽는다)
    let hidden = ChargeConfig.hiddenProviders
    let visible = ChargeConfig.sortedByUserOrder(providers.filter { !hidden.contains($0.id) })
    guard !selection.isEmpty else { return visible }
    let ids = Set(selection.map(\.id))
    return visible.filter { ids.contains($0.id) }
}

private func loadProviders(selection: [ProviderEntity]) async -> [Provider] {
    guard let providers = await ChargeAPI.fetchAllOrCached()?.providers else { return [] }
    return selectedProviders(providers, selection: selection)
}

private func providerTimeline(selection: [ProviderEntity], style: ProviderWidgetStyle) async -> Timeline<ProviderEntry> {
    let providers = await loadProviders(selection: selection)
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
            providers: selectedProviders(sampleProviders, selection: configuration.providers),
            style: .bars
        )
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        await providerTimeline(selection: configuration.providers, style: .bars)
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
            providers: selectedProviders(sampleProviders, selection: configuration.providers),
            style: style
        )
    }

    func timeline(for configuration: SelectLockProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        await providerTimeline(selection: configuration.providers, style: style)
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
    let title: String
    let window: RateWindow?
    /// 스몰 위젯에 프로바이더가 하나뿐일 때 넓게 그리기 위한 확장 모드
    var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = window?.displayState(at: context.date)
            VStack(alignment: .leading, spacing: expanded ? 3 : 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(expanded ? Font.caption : Font.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let state {
                        Text("\(Int(state.window.percent))%")
                            .font((expanded ? Font.caption : Font.caption2).monospacedDigit().bold())
                    }
                }
                WidgetUsageGauge(
                    state: state,
                    tint: gaugeTint(state?.window.percent ?? 0),
                    track: .white.opacity(0.14),
                    marker: .white.opacity(0.92),
                    barHeight: expanded ? 6 : 4,
                    markerHeight: expanded ? 12 : 9
                )
                if expanded, let reset = state?.window.resetShort {
                    Text("Resets in \(reset)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(state?.isEstimated == true ? 0.62 : 1)
        }
    }
}

private struct ProviderColumn: View {
    let provider: Provider
    /// 한 칸에 프로바이더가 여럿이면 이름을 생략하고 마크만 표시한다 (이름 잘림 방지 — 마크로 충분히 구분됨)
    var showName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 5) {
                    ProviderGlyph(providerId: provider.id, name: provider.name)
                        .frame(width: 13, height: 13)
                    if showName {
                        Text(provider.name)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                Spacer(minLength: 4)
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            ProviderBar(
                title: provider.session?.label ?? String(localized: "Session"),
                window: provider.session
            )
            ProviderBar(
                title: provider.weekly?.label ?? String(localized: "Weekly"),
                window: provider.weekly
            )
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

    private func compactWindowLabel(_ window: RateWindow?, fallback: String) -> String {
        guard let label = window?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return fallback
        }
        let initials = label.split(separator: " ").prefix(2).compactMap(\.first)
        return initials.isEmpty ? fallback : String(initials).uppercased()
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
            } else if let only = providers.first, providers.count == 1 {
                // 하나뿐이면 위 절반만 쓰지 않고 위젯 전체를 채운다
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 이름이 절대 잘리지 않게: 감싼 스택에 우선순위 + 고정폭, 플랜 쪽이 줄어든다
                    HStack(spacing: 5) {
                        ProviderGlyph(providerId: only.id, name: only.name)
                            .frame(width: 15, height: 15)
                        Text(only.name)
                            .font(.headline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    if let plan = only.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
                Spacer(minLength: 2)
                ProviderBar(
                    title: only.session?.label ?? String(localized: "Session"),
                    window: only.session,
                    expanded: true
                )
                Spacer(minLength: 2)
                ProviderBar(
                    title: only.weekly?.label ?? String(localized: "Weekly"),
                    window: only.weekly,
                    expanded: true
                )
            } else {
                ForEach(providers, id: \.uid) { provider in
                    ProviderColumn(provider: provider, showName: false)
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
                    ProviderColumn(provider: provider, showName: providers.count == 1)
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
            // CodexBar 스타일: 프로바이더 마크 + 큰 퍼센트
            VStack(spacing: 2) {
                ProviderGlyph(providerId: mostUrgent?.id ?? "", name: mostUrgent?.name ?? "-")
                    .frame(width: 18, height: 18)
                Text("\(estimatePrefix)\(percent)%")
                    .font(.system(.title3, design: .rounded).bold())
                    .minimumScaleFactor(0.55)
            }
            .opacity(state?.isEstimated == true ? 0.58 : 1)
            .containerBackground(.fill.tertiary, for: .widget)
        default:
            Gauge(value: min(state?.window.percent ?? 0, 100), in: 0...100) {
                ProviderGlyph(providerId: mostUrgent?.id ?? "", name: mostUrgent?.name ?? "-")
                    .frame(width: 12, height: 12)
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
                            ProviderGlyph(providerId: provider.id, name: provider.name)
                                .frame(width: 11, height: 11)
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
                    HStack(spacing: 4) {
                        ProviderGlyph(providerId: provider.id, name: provider.name)
                            .frame(width: 12, height: 12)
                        Text(provider.name)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 3)
                    if let plan = provider.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(compactWindowLabel(provider.session, fallback: "S"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(session?.window.percent ?? 0))%")
                        .font(.system(.title3, design: .rounded).bold().monospacedDigit())
                        .opacity(session?.isEstimated == true ? 0.58 : 1)
                    Spacer(minLength: 8)
                    Text(compactWindowLabel(provider.weekly, fallback: "W"))
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
