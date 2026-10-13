import SwiftUI
import WidgetKit

/// What's left of this month's plan. Small: the number and a bar on the brand green. Medium
/// and large add the budgets with their icons. Lock Screen: a gauge, a line, or a bar.
struct LeftToSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.leftToSpend, provider: SnapshotProvider()) { entry in
            LeftToSpendView(entry: entry)
                .widgetURL(WidgetLink.budget)
        }
        .configurationDisplayName("Left to Spend")
        .description("What's left of this month's budget, and how each budget is doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct LeftToSpendView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular.containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            rectangular.containerBackground(.clear, for: .widget)
        case .accessoryInline:
            inline.containerBackground(.clear, for: .widget)
        case .systemMedium:
            medium
        case .systemLarge:
            large
        default:
            small
        }
    }

    private var monthLabel: String {
        (entry.snapshot?.month ?? entry.date).formatted(.dateTime.month(.abbreviated))
    }

    // MARK: Home Screen

    private var small: some View {
        Group {
            if let snapshot = entry.snapshot {
                summary(snapshot)
                    .padding(14)
            } else {
                OpenAppPrompt(onGreen: true).padding(14)
            }
        }
        .containerBackground(for: .widget) { BrandBackground() }
    }

    private var medium: some View {
        Group {
            if let snapshot = entry.snapshot {
                HStack(spacing: 0) {
                    summary(snapshot)
                        .padding(14)
                        .frame(width: 150)
                        .frame(maxHeight: .infinity)
                        .background { BrandBackground() }
                    budgetList(snapshot, limit: 3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            } else {
                OpenAppPrompt().padding(14)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var large: some View {
        Group {
            if let snapshot = entry.snapshot {
                VStack(spacing: 0) {
                    summary(snapshot, isWide: true)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background { BrandBackground() }
                    budgetList(snapshot, limit: 6)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            } else {
                OpenAppPrompt().padding(16)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    /// The green panel: header, what's left, the bar, spent of planned.
    private func summary(_ snapshot: WidgetSnapshot, isWide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Budget", trailing: monthLabel, onGreen: true)
            Spacer(minLength: isWide ? 10 : 0)
            Text(snapshot.leftCents >= 0 ? "Left to spend" : "Over plan")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(Money.whole(abs(snapshot.leftCents)))
                .font(.system(size: isWide ? 34 : 26, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
                .privacySensitive()
            ThinBar(
                progress: snapshot.progress,
                color: snapshot.leftCents >= 0 ? .white : Color(hex: 0xFFB4B4),
                track: .white.opacity(0.25),
                height: 6
            )
            .padding(.vertical, 2)
            Text(snapshot.budgetedCents > 0 ? "\(Money.whole(snapshot.spentCents)) of \(Money.whole(snapshot.budgetedCents))" : "No plan yet")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The budgets in the app's order, each with its icon, what's left and a bar.
    private func budgetList(_ snapshot: WidgetSnapshot, limit: Int) -> some View {
        let budgets = Array(snapshot.budgets.prefix(limit))
        return VStack(alignment: .leading, spacing: 0) {
            if budgets.isEmpty {
                Text("No budgets yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(budgets) { budget in
                    HStack(spacing: 10) {
                        BudgetIcon(symbol: budget.symbol, color: budget.color)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(budget.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(budget.limitCents > 0 ? leftText(budget.leftCents) : Money.whole(budget.spentCents))
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(budget.leftCents >= 0 || budget.limitCents == 0 ? Color.secondary : Brand.expenseInk)
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                            ThinBar(progress: budget.progress, color: budget.leftCents >= 0 ? budget.color.color : Brand.expense)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        Group {
            if let snapshot = entry.snapshot {
                Gauge(value: max(0, 1 - min(snapshot.progress, 1))) {
                    Image(systemName: "chart.pie")
                } currentValueLabel: {
                    Text(compact(snapshot.leftCents))
                        .monospacedDigit()
                        .privacySensitive()
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                Image(systemName: "chart.pie")
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Budget · \(monthLabel)", systemImage: "chart.pie")
                .font(.caption2.weight(.semibold))
            if let snapshot = entry.snapshot {
                Text(leftText(snapshot.leftCents))
                    .font(.headline)
                    .monospacedDigit()
                    .privacySensitive()
                Gauge(value: min(snapshot.progress, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
            } else {
                Text("Open Suffice").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Group {
            if let snapshot = entry.snapshot {
                Label("\(leftText(snapshot.leftCents)) in \(monthLabel)", systemImage: "chart.pie")
            } else {
                Label("Suffice", systemImage: "chart.pie")
            }
        }
    }

    /// "$1.2k", "$840", "−$90", to fit inside the circular gauge.
    private func compact(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        let sign = dollars < 0 ? "−" : ""
        let value = abs(dollars)
        if value >= 1000 {
            return "\(sign)$\(String(format: value >= 10_000 ? "%.0f" : "%.1f", value / 1000))k"
        }
        return "\(sign)$\(Int(value.rounded()))"
    }
}

#Preview(as: .systemSmall) {
    LeftToSpendWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview(as: .systemMedium) {
    LeftToSpendWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview(as: .accessoryRectangular) {
    LeftToSpendWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
