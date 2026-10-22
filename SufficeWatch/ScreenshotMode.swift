import Foundation

/// Screenshot mode on Apple Watch, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, the watch app shows the demo household from the iPhone's
/// screenshot mode (Suffice/App/ScreenshotMode.swift) from a snapshot made in memory. It doesn't
/// talk to the iPhone, doesn't read or write the snapshot in the app group and doesn't reload the
/// complications, so the real numbers are never touched. Adding `-Screen <name>` opens one page
/// (see `Screen`). Debug builds only: Release ignores the arguments, so none of this can be
/// reached in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The pages the script captures, by the name passed after `-Screen`, in the screenshots' order.
    nonisolated enum Screen: String, CaseIterable {
        case left, budgets, bills

        var page: WatchPage {
            switch self {
            case .left: .leftToSpend
            case .budgets: .budgets
            case .bills: .bills
            }
        }
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// Daniel and Maya's month, as their iPhone would send it: the starter budgets with the demo
    /// amounts (subcategories rolled into their budget), a month of spending so far, and the
    /// bills coming up in the next two weeks. Dates are counted from `now`, so it always looks
    /// current.
    static func demoSnapshot(now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        typealias Budget = WidgetSnapshot.Budget
        typealias Due = WidgetSnapshot.Due
        let budgets = [
            Budget(id: UUID(), name: "Home", symbol: "house", color: .orange, spentCents: 2_081_65, limitCents: 2_235_00),
            Budget(id: UUID(), name: "Auto", symbol: "car", color: .blue, spentCents: 307_40, limitCents: 384_00),
            Budget(id: UUID(), name: "Food", symbol: "fork.knife", color: .red, spentCents: 768_35, limitCents: 1_010_00),
            Budget(id: UUID(), name: "Utilities", symbol: "bolt", color: .green, spentCents: 64_12, limitCents: 445_00),
            Budget(id: UUID(), name: "Entertainment", symbol: "ticket", color: .purple, spentCents: 134_89, limitCents: 245_00),
            Budget(id: UUID(), name: "Giving", symbol: "heart", color: .yellow, spentCents: 225_00, limitCents: 250_00),
            Budget(id: UUID(), name: "Travel", symbol: "airplane", color: .teal, spentCents: 286_40, limitCents: 300_00),
        ]
        return WidgetSnapshot(
            // A couple of minutes ago, so the page reads "Updated 2 minutes ago".
            updated: now.addingTimeInterval(-120),
            month: calendar.dateInterval(of: .month, for: now)?.start ?? today,
            budgetedCents: budgets.reduce(0) { $0 + $1.limitCents },
            spentCents: budgets.reduce(0) { $0 + $1.spentCents },
            incomeCents: 7_690_00,
            cashCents: 27_047_57,
            budgets: budgets,
            dues: [
                Due(billID: UUID(), name: "Brightline Wireless", amountCents: 142_00, date: day(1), color: .pink, isPaid: false, isAutopay: true, isSubscription: false),
                Due(billID: UUID(), name: "StreamBox", amountCents: 15_49, date: day(2), color: .red, isPaid: false, isAutopay: true, isSubscription: true),
                Due(billID: UUID(), name: "Valley Power", amountCents: 128_44, date: day(3), color: .yellow, isPaid: false, isAutopay: false, isSubscription: false),
                Due(billID: UUID(), name: "Fiberlink Internet", amountCents: 73_00, date: day(5), color: .purple, isPaid: false, isAutopay: true, isSubscription: false),
                Due(billID: UUID(), name: "CloudDrive 2 TB", amountCents: 9_99, date: day(11), color: .blue, isPaid: false, isAutopay: true, isSubscription: true),
            ]
        )
    }
}
