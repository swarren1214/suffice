import SwiftUI
import WidgetKit

/// One moment in a widget's timeline: the snapshot the app last wrote, seen from `date`.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written anything (installed but never opened).
    let snapshot: WidgetSnapshot?
}

/// Every Suffice widget reads the same snapshot. Timelines step through the next few
/// midnights so "Due tomorrow" turns into "Due today" without the app opening.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = WidgetStore.load()
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? (stored ?? .sample) : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var entries = [SnapshotEntry(date: .now, snapshot: snapshot)]
        for offset in 1...3 {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: today) {
                entries.append(SnapshotEntry(date: midnight, snapshot: snapshot))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension WidgetSnapshot {
    /// What the widget gallery shows, and what a widget shows while it loads.
    static var sample: WidgetSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        return WidgetSnapshot(
            updated: .now,
            month: MonthStart.of(.now),
            budgetedCents: 5_200_00,
            spentCents: 3_046_18,
            incomeCents: 6_400_00,
            cashCents: 8_412_55,
            budgets: [
                Budget(id: UUID(), name: "Home", symbol: "house", color: .orange, spentCents: 2_201_79, limitCents: 2_400_00),
                Budget(id: UUID(), name: "Groceries", symbol: "cart", color: .green, spentCents: 512_40, limitCents: 900_00),
                Budget(id: UUID(), name: "Dining Out", symbol: "fork.knife", color: .red, spentCents: 188_25, limitCents: 250_00),
                Budget(id: UUID(), name: "Auto", symbol: "car", color: .blue, spentCents: 143_74, limitCents: 400_00),
                Budget(id: UUID(), name: "Utilities", symbol: "bolt", color: .yellow, spentCents: 0, limitCents: 350_00),
                Budget(id: UUID(), name: "Kids", symbol: "figure.2.and.child.holdinghands", color: .purple, spentCents: 0, limitCents: 300_00),
            ],
            dues: [
                Due(billID: UUID(), name: "T-Mobile", amountCents: 161_06, date: day(0), color: .pink, isPaid: false, isAutopay: true, isSubscription: false),
                Due(billID: UUID(), name: "Dominion Energy", amountCents: 76_27, date: day(2), color: .blue, isPaid: false, isAutopay: false, isSubscription: false),
                Due(billID: UUID(), name: "Mortgage", amountCents: 2_201_79, date: day(4), color: .orange, isPaid: false, isAutopay: false, isSubscription: false),
                Due(billID: UUID(), name: "Netflix", amountCents: 17_99, date: day(7), color: .red, isPaid: false, isAutopay: true, isSubscription: true),
                Due(billID: UUID(), name: "Rocky Mountain Power", amountCents: 77_78, date: day(12), color: .blue, isPaid: false, isAutopay: false, isSubscription: false),
            ]
        )
    }
}

enum MonthStart {
    static func of(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }
}
