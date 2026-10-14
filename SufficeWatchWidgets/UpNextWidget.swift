import SwiftUI
import WidgetKit

/// The Smart Stack card that knows the moment: bills due today in the morning, dining out
/// around lunch and dinner, groceries on weekend mornings, and otherwise the budget closest to
/// its amount. The timeline covers the next day, each entry with its own relevance, so the
/// Smart Stack brings it up when it matters and lets it sink when it doesn't.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.watchUpNext, provider: UpNextProvider()) { entry in
            UpNextView(entry: entry)
                .containerBackground(Brand.green.gradient, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("Bills due today, and the budget that matters right now.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct UpNextEntry: TimelineEntry {
    enum Moment: Hashable {
        /// Bills due today (and any late ones).
        case bills([WidgetSnapshot.Due])
        /// A budget worth a look right now.
        case budget(WidgetSnapshot.Budget, reason: String)
        case nothing
    }

    let date: Date
    let moment: Moment
    var relevance: TimelineEntryRelevance?
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, moment: .budget(WidgetSnapshot.watchSample.budgets[0], reason: "Dinner time"))
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        let snapshot = WidgetStore.load() ?? (context.isPreview ? .watchSample : nil)
        completion(Self.entry(at: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        let calendar = Calendar.current
        let now = Date.now
        // An entry now, then at each moment that changes what matters over the next day.
        var dates = [now]
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for hour in [0, 7, 10, 11, 14, 17, 21] {
                if let date = calendar.date(byAdding: .hour, value: hour, to: day), date > now {
                    dates.append(date)
                }
            }
        }
        let entries = dates.sorted().map { Self.entry(at: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// What matters at `date`, and how much.
    static func entry(at date: Date, snapshot: WidgetSnapshot?, calendar: Calendar = .current) -> UpNextEntry {
        guard let snapshot else { return UpNextEntry(date: date, moment: .nothing, relevance: TimelineEntryRelevance(score: 0)) }
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        let dueToday = snapshot.unpaid.filter { $0.date < endOfDay }

        // Mornings: today's bills (and any late ones) come first.
        if !dueToday.isEmpty, (7..<14).contains(hour) {
            return UpNextEntry(date: date, moment: .bills(dueToday), relevance: TimelineEntryRelevance(score: 90, duration: 7 * 3600))
        }
        // Meal times: dining out.
        if (11..<14).contains(hour) || (17..<21).contains(hour), let dining = snapshot.budget(matching: diningWords) {
            let reason = hour < 14 ? "Lunch time" : "Dinner time"
            return UpNextEntry(date: date, moment: .budget(dining, reason: reason), relevance: TimelineEntryRelevance(score: dining.progress >= 0.8 ? 70 : 45, duration: 3 * 3600))
        }
        // Weekend mornings: groceries.
        if isWeekend, (7..<11).contains(hour), let groceries = snapshot.budget(matching: groceryWords) {
            return UpNextEntry(date: date, moment: .budget(groceries, reason: "Shopping day"), relevance: TimelineEntryRelevance(score: 40, duration: 4 * 3600))
        }
        // Otherwise: late bills, or the budget closest to its amount.
        if !dueToday.isEmpty {
            return UpNextEntry(date: date, moment: .bills(dueToday), relevance: TimelineEntryRelevance(score: 40))
        }
        if let tight = snapshot.tightestBudget, tight.progress >= 0.8 {
            return UpNextEntry(date: date, moment: .budget(tight, reason: tight.progress > 1 ? "Over budget" : "Running low"), relevance: TimelineEntryRelevance(score: 30))
        }
        if let tight = snapshot.tightestBudget {
            return UpNextEntry(date: date, moment: .budget(tight, reason: "This month"), relevance: TimelineEntryRelevance(score: 5))
        }
        return UpNextEntry(date: date, moment: .nothing, relevance: TimelineEntryRelevance(score: 0))
    }

    private static let diningWords = ["dining", "restaurant", "eating out", "eat out", "takeout", "fast food", "fork.knife"]
    private static let groceryWords = ["grocer", "food at home", "supermarket", "cart"]
}

extension WidgetSnapshot {
    /// The first budget whose name or icon matches one of `words`.
    func budget(matching words: [String]) -> Budget? {
        budgets.first { budget in
            let name = budget.name.lowercased()
            return words.contains { name.contains($0) || budget.symbol.hasPrefix($0) }
        }
    }
}

struct UpNextView: View {
    var entry: UpNextEntry

    var body: some View {
        switch entry.moment {
        case .bills(let dues):
            VStack(alignment: .leading, spacing: 2) {
                Label(dues.count == 1 ? "Due today" : "\(dues.count) bills due", systemImage: "calendar.badge.clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(dues.first?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(dues.count == 1 ? Money.text(dues[0].amountCents) : "\(Money.text(dues.reduce(0) { $0 + $1.amountCents })) in all")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .budget(let budget, let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("\(reason) · \(budget.name)", systemImage: budget.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(leftLabel(budget.leftCents))
                    .font(.headline)
                    .monospacedDigit()
                Gauge(value: remainingFraction(spent: budget.spentCents, limit: budget.limitCents)) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(budget.leftCents >= 0 ? Color.white : Color.red)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .nothing:
            NoDataView()
        }
    }
}
