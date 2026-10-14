import SwiftUI
import WidgetKit

/// "Left to spend": what's left of everything planned this month, as a ring that empties as
/// you spend and goes from green to red.
struct LeftToSpendComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.watchLeftToSpend, provider: LeftToSpendProvider()) { entry in
            LeftToSpendView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Left to Spend")
        .description("What's left of this month's budget.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var relevance: TimelineEntryRelevance?
}

struct LeftToSpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .watchSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetStore.load() ?? (context.isPreview ? .watchSample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        // More relevant in the Smart Stack the closer the month gets to its limit.
        let score = Float(min(snapshot?.progress ?? 0, 1.2) * 50)
        let entry = SnapshotEntry(date: .now, snapshot: snapshot, relevance: TimelineEntryRelevance(score: score))
        // The watch app reloads this whenever the iPhone sends new numbers.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct LeftToSpendView: View {
    var snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot {
            let left = snapshot.leftCents
            let remaining = remainingFraction(spent: snapshot.spentCents, limit: snapshot.budgetedCents)
            switch family {
            case .accessoryCircular:
                Gauge(value: remaining) {
                    Image(systemName: "dollarsign")
                } currentValueLabel: {
                    Text(Money.compact(left))
                        .minimumScaleFactor(0.5)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(leftGradient)
                .widgetAccentable()
            case .accessoryCorner:
                Text(Money.compact(left))
                    .widgetCurvesContent()
                    .widgetLabel {
                        Gauge(value: remaining) {
                            Text("Left")
                        }
                        .tint(leftGradient)
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Left to spend")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(leftLabel(left))
                        .font(.headline)
                        .monospacedDigit()
                        .widgetAccentable()
                    Gauge(value: remaining) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(leftGradient)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Text("\(leftLabel(left)) this month")
            }
        } else {
            NoDataView()
        }
    }
}
