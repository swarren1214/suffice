import SwiftUI
import WidgetKit

/// Overview's Total cash, with this month's income and spending.
struct TotalCashWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.cash, provider: SnapshotProvider()) { entry in
            TotalCashView(entry: entry)
                .widgetURL(WidgetLink.overview)
        }
        .configurationDisplayName("Total Cash")
        .description("Cash across the accounts in your budget, and this month's income and spending.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct TotalCashView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                rectangular
            } else {
                small
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Total cash", trailing: nil)
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                Text(Money.whole(snapshot.cashCents))
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .privacySensitive()
                Divider().padding(.vertical, 3)
                line("In", snapshot.incomeCents, color: Brand.green)
                line("Out", snapshot.spentCents, color: Brand.expenseInk)
            } else {
                Text("Open Suffice to add your accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func line(_ title: String, _ cents: Int, color: Color) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(Money.whole(cents))
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .monospacedDigit()
                .privacySensitive()
        }
        .font(.caption)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Total cash", systemImage: "building.columns")
                .font(.caption2.weight(.semibold))
            if let snapshot = entry.snapshot {
                Text(Money.whole(snapshot.cashCents))
                    .font(.headline)
                    .monospacedDigit()
                    .privacySensitive()
                Text("In \(Money.whole(snapshot.incomeCents)) · Out \(Money.whole(snapshot.spentCents))")
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .privacySensitive()
            } else {
                Text("Open Suffice").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemSmall) {
    TotalCashWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
