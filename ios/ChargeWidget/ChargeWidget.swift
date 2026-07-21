import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let todayCost: Double
    let todayTokens: Int
    let weekCost: Double
    let blockCost: Double?
    let blockProgress: Double?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, todayCost: 12.34, todayTokens: 5_200_000,
                   weekCost: 61.20, blockCost: 4.10, blockProgress: 0.4)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            var entry = UsageEntry(date: .now, todayCost: 0, todayTokens: 0,
                                   weekCost: 0, blockCost: nil, blockProgress: nil)
            if let payload = await ChargeAPI.fetchAllOrCached() {
                let today = payload.daily.first { $0.period == ChargeDate.todayString() }
                entry = UsageEntry(
                    date: .now,
                    todayCost: today?.totalCost ?? 0,
                    todayTokens: today?.totalTokens ?? 0,
                    weekCost: payload.daily.suffix(7).reduce(0) { $0 + $1.totalCost },
                    blockCost: payload.live?.costUSD,
                    blockProgress: payload.live?.windowProgress
                )
            }
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct ChargeWidgetView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(fmtUSD(entry.todayCost))
                .font(.system(.title2, design: .rounded).bold())
                .minimumScaleFactor(0.6)
            Text("\(fmtTokens(entry.todayTokens)) tok, 7d \(fmtUSD(entry.weekCost))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let cost = entry.blockCost, let progress = entry.blockProgress {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("5h \(fmtUSD(cost))")
                            .font(.caption2)
                        Spacer()
                    }
                    ProgressView(value: progress)
                        .tint(.green)
                        .scaleEffect(y: 0.7)
                }
            } else {
                Text("No active session")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .containerBackground(for: .widget) { ChargeTheme.background }
        .environment(\.colorScheme, .dark)
    }
}

@main
struct ChargeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChargeWidget()
        ProviderWidget()
    }
}

struct ChargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChargeWidget", provider: UsageProvider()) { entry in
            ChargeWidgetView(entry: entry)
        }
        .configurationDisplayName("Token Usage")
        .description("Today's AI coding cost and the current 5h window.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
