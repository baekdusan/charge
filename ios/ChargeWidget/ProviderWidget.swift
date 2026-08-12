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

/// 지금 그릴 수 있는 창 한 줄 (세션, 주간). 창이 없는 프로바이더를 0%로 그리면
/// "한도를 안 썼다"는 거짓말이 되므로, 앱 카드처럼 줄 자체를 만들지 않는다.
private struct ProviderRow: Identifiable {
    let id: String
    let title: String
    let window: RateWindow
}

private func displayRows(_ provider: Provider, at now: Date) -> [ProviderRow] {
    var rows: [ProviderRow] = []
    if let s = provider.session, s.displayState(at: now) != nil {
        rows.append(ProviderRow(id: "session", title: s.label ?? String(localized: "Session"), window: s))
    }
    if let w = provider.weekly, w.displayState(at: now) != nil {
        rows.append(ProviderRow(id: "weekly", title: w.label ?? String(localized: "Weekly"), window: w))
    }
    return rows
}

/// 창이 없을 때 쓰는 표기, 숫자를 쓰는 순간 "한도를 안 썼다"는 단언이 된다
private func percentText(_ state: RateWindowDisplayState?) -> String {
    guard let state else { return ", " }
    return "\(state.isEstimated ? "~" : "")\(Int(state.window.percent))%"
}

/// 프로바이더 하나가 묵었는지, 임계값은 앱 카드와 공유한다(ChargeFreshness).
/// 판정은 언제나 프로바이더 단위다: 전체 최댓값으로 보면 Codex가 정상 수집되는 동안
/// 세 시간 묵은 Claude 막대가 흐림 없이 밝게 그려진다.
private func isStale(_ provider: Provider, at now: Date) -> Bool {
    provider.freshness(at: now).isStale
}

/// 지금 그려지고 있는 항목 가운데 "가장 낡은" 판정 하나, 넓은 패밀리의 나이 한 줄용.
/// 전부 신선하거나 수집 시각 미상이면 nil이라 줄 자체가 사라진다.
private func oldestStale(_ providers: [Provider], at now: Date) -> CollectionFreshness? {
    let stale = providers.map { $0.freshness(at: now) }.filter(\.isStale)
    guard !stale.isEmpty else { return nil }
    // 시각을 못 믿는 항목이 하나라도 섞였으면 나이를 숫자로 말하지 않는다
    if stale.contains(where: { $0.ageDate == nil }) { return .untrusted }
    return stale.min { ($0.ageDate ?? .distantFuture) < ($1.ageDate ?? .distantFuture) }
}

/// 나이 한 줄 문구, nil이면 줄을 만들지 않는다
private func ageLineText(_ providers: [Provider], at now: Date) -> String? {
    guard let oldest = oldestStale(providers, at: now) else { return nil }
    guard let date = oldest.ageDate else {
        // 시각이 비상식적이라 나이를 못 말한다, 그래도 침묵하면 가장 낡은 값이 정상으로 읽힌다
        return String(localized: "Data out of date")
    }
    return String(localized: "Data from \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
}

private struct WidgetUsageGauge: View {
    let state: RateWindowDisplayState
    let tint: Color
    let track: Color
    let marker: Color
    var barHeight: CGFloat = 4
    var markerHeight: CGFloat = 9

    var body: some View {
        let usage = min(1, max(0, state.window.percent / 100))
        let timeProgress = state.window.timeProgress
        let isEstimated = state.isEstimated

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
        .accessibilityValue("\(Int(state.window.percent)) percent")
    }
}

private struct ProviderBar: View {
    let title: String
    let window: RateWindow
    /// 위젯 루트의 시계가 흘려보낸 "지금", 리셋 추정도 신선도도 같은 시각을 본다
    let now: Date
    /// 스몰 위젯에 프로바이더가 하나뿐일 때 넓게 그리기 위한 확장 모드
    var expanded = false
    /// 이 프로바이더의 스냅샷이 오래됐을 때, 추정값(isEstimated)과 같은 톤으로 낮춘다
    var stale = false

    var body: some View {
        // 리셋 뒤 다음 창을 추정할 수 없는 창은 0%가 아니라 줄 자체를 생략한다
        if let state = window.displayState(at: now) {
            VStack(alignment: .leading, spacing: expanded ? 3 : 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(expanded ? Font.caption : Font.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(Int(state.window.percent))%")
                        .font((expanded ? Font.caption : Font.caption2).monospacedDigit().bold())
                }
                WidgetUsageGauge(
                    state: state,
                    tint: gaugeTint(state.window.percent),
                    track: .white.opacity(0.14),
                    marker: .white.opacity(0.92),
                    barHeight: expanded ? 6 : 4,
                    markerHeight: expanded ? 12 : 9
                )
                if expanded, let reset = state.window.resetShort {
                    Text("Resets in \(reset)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(state.isEstimated || stale ? 0.62 : 1)
        }
    }
}

private struct ProviderColumn: View {
    let provider: Provider
    /// 위젯 루트의 시계가 흘려보낸 "지금"
    let now: Date
    /// 한 칸에 프로바이더가 여럿이면 이름을 생략하고 마크만 표시한다 (이름 잘림 방지 — 마크로 충분히 구분됨)
    var showName = true
    /// 이 프로바이더만의 신선도, 옆 칸이 신선해도 이 칸은 이 값으로 판단한다
    var stale = false

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
            ForEach(displayRows(provider, at: now)) { row in
                ProviderBar(title: row.title, window: row.window, now: now, stale: stale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Family views

struct ProviderWidgetView: View {
    var entry: ProviderEntry
    @Environment(\.widgetFamily) private var family

    /// 그릴 창이 하나도 없는 프로바이더는 위젯에서도 뺀다, 앱 카드가 행을 생략하는 것과 같은 규칙
    private func visibleProviders(at now: Date) -> [Provider] {
        entry.providers.filter { !displayRows($0, at: now).isEmpty }
    }

    /// 세션 창만 그리는 패밀리(바, 인라인)용, 세션이 없는 프로바이더는 그릴 것이 없다
    private func sessionProviders(at now: Date) -> [Provider] {
        entry.providers.filter { $0.session?.displayState(at: now) != nil }
    }

    private func mostUrgent(at now: Date) -> Provider? {
        sessionProviders(at: now).max {
            ($0.session?.displayState(at: now)?.window.percent ?? 0)
                < ($1.session?.displayState(at: now)?.window.percent ?? 0)
        } ?? visibleProviders(at: now).first
    }

    /// 흐림만으로는 "언제 것인지"를 못 말한다, 자리가 있는 패밀리에만 한 줄 덧붙인다.
    /// 지금 그려지고 있는 항목 중 가장 낡은 것 기준이고, 전부 신선하면 줄이 사라진다.
    /// 그릴 창이 하나도 없어 "No data"로 가는 경우엔 걸러지기 전 목록으로 판정한다 , 
    /// 수집기가 몇 시간 죽어 있으면 창이 전부 사라지는데(리셋 추정도 못 하는 상태),
    /// 그때 앱 카드는 나이를 말하는데 위젯만 "No data"로 침묵하는 게 최악이다.
    @ViewBuilder
    private func ageLine(_ providers: [Provider], at now: Date) -> some View {
        if let text = ageLineText(providers.isEmpty ? entry.providers : providers, at: now) {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// 위젯 안에서 계속 흐르는 "지금". 신선도를 엔트리 렌더 시점의 Date()로 굳히면,
    /// WidgetKit이 타임라인을 갱신하지 못하는 상황(예산 소진, 네트워크 없음 = 데이터가 가장 낡은 상황)에서
    /// 흐림도 나이 문구도 영영 나오지 않는다, 그래서 판정을 전부 이 시각 안으로 옮겼다.
    private func clock<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(context.date)
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            clock { circularView(at: $0) }
                .containerBackground(.fill.tertiary, for: .widget)
        case .accessoryRectangular:
            clock { rectangularView(at: $0) }
                .containerBackground(.fill.tertiary, for: .widget)
        case .accessoryInline:
            clock { inlineView(at: $0) }
                .containerBackground(.fill.tertiary, for: .widget)
        case .systemMedium:
            clock { mediumView(at: $0) }
                .containerBackground(for: .widget) { ChargeTheme.background }
                .environment(\.colorScheme, .dark)
        default:
            clock { smallView(at: $0) }
                .containerBackground(for: .widget) { ChargeTheme.background }
                .environment(\.colorScheme, .dark)
        }
    }

    private func smallView(at now: Date) -> some View {
        let providers = Array(visibleProviders(at: now).prefix(2))

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
                ForEach(displayRows(only, at: now)) { row in
                    Spacer(minLength: 2)
                    ProviderBar(
                        title: row.title,
                        window: row.window,
                        now: now,
                        expanded: true,
                        stale: isStale(only, at: now)
                    )
                }
            } else {
                ForEach(providers, id: \.uid) { provider in
                    // 프로바이더마다 자기 수집 시각으로 판정한다, 옆 칸이 신선해도 이 칸은 흐려질 수 있다
                    ProviderColumn(provider: provider, now: now, showName: false, stale: isStale(provider, at: now))
                }
            }
            Spacer(minLength: 0)
            ageLine(providers, at: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumView(at now: Date) -> some View {
        let providers = Array(visibleProviders(at: now).prefix(2))

        return VStack(alignment: .leading, spacing: 6) {
            if providers.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(providers, id: \.uid) { provider in
                        ProviderColumn(
                            provider: provider,
                            now: now,
                            showName: providers.count == 1,
                            stale: isStale(provider, at: now)
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            ageLine(providers, at: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func circularView(at now: Date) -> some View {
        let provider = mostUrgent(at: now)
        let state = provider?.session?.displayState(at: now)
        // 세션 창이 없으면 링을 비운 채 ", ", 0%로 채우면 "한도를 안 썼다"고 말하게 된다
        let text = percentText(state)
        // 한 프로바이더만 그리는 패밀리라 신선도도 그 프로바이더 것만 본다
        let dimmed = state?.isEstimated == true || (provider.map { isStale($0, at: now) } ?? false)

        switch entry.style {
        case .number:
            // CodexBar 스타일: 프로바이더 마크 + 큰 퍼센트
            VStack(spacing: 2) {
                ProviderGlyph(providerId: provider?.id ?? "", name: provider?.name ?? "-")
                    .frame(width: 18, height: 18)
                Text(text)
                    .font(.system(.title3, design: .rounded).bold())
                    .minimumScaleFactor(0.55)
            }
            .opacity(dimmed ? 0.58 : 1)
        default:
            Gauge(value: state.map { min($0.window.percent, 100) } ?? 0, in: 0...100) {
                ProviderGlyph(providerId: provider?.id ?? "", name: provider?.name ?? "-")
                    .frame(width: 12, height: 12)
            } currentValueLabel: {
                Text(text)
                    .font(.system(.body, design: .rounded).bold())
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircular)
            .opacity(dimmed ? 0.58 : 1)
        }
    }

    @ViewBuilder
    private func rectangularView(at now: Date) -> some View {
        switch entry.style {
        case .bars:
            lockBarsView(at: now)
        default:
            lockSummaryView(at: now)
        }
    }

    private func lockBarsView(at now: Date) -> some View {
        // 세션 창이 있는 프로바이더만, 창이 없는 줄은 0%로 그리는 대신 빼버린다
        let providers = Array(sessionProviders(at: now).prefix(2))

        return VStack(alignment: .leading, spacing: 5) {
            if providers.isEmpty {
                Text("No data").font(.caption2)
            } else {
                ForEach(providers, id: \.uid) { provider in
                    if let state = provider.session?.displayState(at: now) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                ProviderGlyph(providerId: provider.id, name: provider.name)
                                    .frame(width: 11, height: 11)
                                Text(provider.name)
                                    .font(.caption2.bold())
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int(state.window.percent))%")
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
                        // 두 줄은 서로 다른 프로바이더다, 한쪽만 묵었으면 그 줄만 낮춘다
                        .opacity(state.isEstimated || isStale(provider, at: now) ? 0.58 : 1)
                    }
                }
            }
            // "No data"로 간 경우에도 아는 수집 시각이 있으면 나이는 말해준다
            ageLine(providers, at: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func lockSummaryView(at now: Date) -> some View {
        let provider = mostUrgent(at: now)
        let session = provider?.session?.displayState(at: now)
        let weekly = provider?.weekly?.displayState(at: now)
        // 한 프로바이더의 세션, 주간을 나란히 보여주는 패밀리, 둘 다 그 프로바이더의 신선도를 따른다
        let stale = provider.map { isStale($0, at: now) } ?? false

        return VStack(alignment: .leading, spacing: 3) {
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
                // 한 줄에 큰 숫자 둘을 나란히 두면 좁은 잠금화면 폭에서 "5…"로 잘린다 —
                // 라벨 위 + 숫자 아래로 쌓고, 숫자는 잘리는 대신 축소되게 한다
                HStack(alignment: .top, spacing: 12) {
                    summaryStat(
                        label: provider.session?.label ?? String(localized: "Session"),
                        state: session,
                        stale: stale
                    )
                    summaryStat(
                        label: provider.weekly?.label ?? String(localized: "Weekly"),
                        state: weekly,
                        stale: stale
                    )
                }
            } else {
                Text("No data").font(.caption2)
            }
            // 그릴 프로바이더가 없어도(창이 전부 사라진 최악의 경우) 나이는 말해준다
            ageLine(provider.map { [$0] } ?? [], at: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func summaryStat(label: String, state: RateWindowDisplayState?, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // 창이 없으면 ", " (0%가 아니다). 묵은 스냅샷이면 숫자를 흐리게 낮춘다
            Text(percentText(state))
                .font(.system(.title3, design: .rounded).bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(state?.isEstimated == true || stale ? 0.58 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineView(at now: Date) -> some View {
        // 세션 창이 없는 프로바이더는 이름만 남기는 대신 아예 빼고, 하나도 없으면 빈 상태 문구로 간다
        let shown = entry.providers.filter { $0.session?.displayState(at: now) != nil }.prefix(2)
        // accessoryInline은 시스템이 날짜 옆 한 줄을 고정 스타일로 그려서 .opacity가 먹지 않는다.
        // 게다가 줄 전체를 낮추면 옆에서 정상 수집 중인 프로바이더까지 같이 낡아 보인다.
        // 그래서 신호를 텍스트 표현 자체에 싣는다, 묵은 값 앞에만 별표를 붙인다.
        // (빼버리는 쪽은 택하지 않았다: 잠금화면에서 이름이 사라지면 "그 프로바이더는 멀쩡하다"로 읽힌다.
        //  물결표는 이미 리셋 추정값 표시라 겹치지 않게 별표를 쓴다, "*34%"는 추정 아닌 묵은 값이다.)
        let parts = shown.map { p in
            let mark = isStale(p, at: now) ? "*" : ""
            return "\(p.name) \(mark)\(percentText(p.session?.displayState(at: now)))"
        }

        return Text(parts.isEmpty ? String(localized: "No data") : parts.joined(separator: " | "))
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
        .description("Session and weekly percentages of your busiest provider.")
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
