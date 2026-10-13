import SwiftUI
import WidgetKit

/// The bills still to pay: late ones first, then what's coming up, with what's owed this week.
struct BillsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.bills, provider: SnapshotProvider()) { entry in
            BillsWidgetView(entry: entry)
                .widgetURL(WidgetLink.bills)
        }
        .configurationDisplayName("Upcoming Bills")
        .description("The next bills to pay, and what's due in the next 7 days.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct BillsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: list(rows: 3)
            case .systemLarge: list(rows: 7)
            default: small
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var unpaid: [WidgetSnapshot.Due] { entry.snapshot?.unpaid ?? [] }

    private var weekTotal: Int { entry.snapshot?.owedThisWeek(from: entry.date) ?? 0 }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Bills", trailing: nil)
            Spacer(minLength: 0)
            if entry.snapshot == nil {
                Text("Open Suffice to add your bills.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let next = unpaid.first {
                BillBadge(name: next.name, color: next.color, size: 30)
                Text(next.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(Money.text(next.amountCents))
                        .monospacedDigit()
                        .privacySensitive()
                    Text("·")
                    Text(dueText(next.date, from: entry.date))
                        .foregroundStyle(isLate(next.date, from: entry.date) ? Brand.expenseInk : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Divider().padding(.vertical, 2)
                weekLine
            } else {
                allPaid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                WidgetHeader(title: "Bills", trailing: nil)
                if !unpaid.isEmpty {
                    weekLine.fixedSize()
                }
            }
            if entry.snapshot == nil {
                Spacer(minLength: 0)
                Text("Open Suffice to add your bills.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if unpaid.isEmpty {
                Spacer(minLength: 0)
                allPaid.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(unpaid.prefix(rows))) { due in
                        row(due)
                            .frame(maxHeight: .infinity)
                    }
                    // Keep rows the same height when there are fewer bills than slots.
                    ForEach(0..<max(0, rows - unpaid.count), id: \.self) { _ in
                        Color.clear.frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ due: WidgetSnapshot.Due) -> some View {
        let late = isLate(due.date, from: entry.date)
        return HStack(spacing: 10) {
            BillBadge(name: due.name, color: due.color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(due.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(due.isAutopay ? "\(dueText(due.date, from: entry.date)) · Autopay" : dueText(due.date, from: entry.date))
                    .font(.caption2)
                    .foregroundStyle(late ? Brand.expenseInk : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Money.text(due.amountCents))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .privacySensitive()
        }
    }

    private var weekLine: some View {
        HStack(spacing: 4) {
            Text("Next 7 days")
                .foregroundStyle(.secondary)
            Text(Money.whole(weekTotal))
                .fontWeight(.semibold)
                .monospacedDigit()
                .privacySensitive()
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private var allPaid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Brand.green)
                .widgetAccentable()
            Text("All paid up")
                .font(.subheadline.weight(.semibold))
            Text("Nothing due in the next 45 days.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Next bill", systemImage: "calendar.badge.clock")
                .font(.caption2.weight(.semibold))
            if let next = unpaid.first {
                Text(next.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(Money.text(next.amountCents)) · \(dueText(next.date, from: entry.date))")
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .privacySensitive()
            } else {
                Text(entry.snapshot == nil ? "Open Suffice" : "All paid up")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Group {
            if let next = unpaid.first {
                Label("\(next.name) \(dueText(next.date, from: entry.date).lowercased())", systemImage: "calendar.badge.clock")
            } else {
                Label("Bills all paid", systemImage: "calendar.badge.clock")
            }
        }
    }
}

#Preview(as: .systemSmall) {
    BillsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview(as: .systemMedium) {
    BillsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
