import Foundation
import OSLog
import SwiftData
import UIKit
import UserNotifications

/// Profile › Reminders, as local notifications on this device:
/// - Bills coming due: 9 AM the day before each due date in the next three weeks, unless the
///   bill is on autopay or already paid.
/// - Budgets running low: once a month per budget when it passes 80%, and again if it goes over.
///   Checked whenever the budget changes (a transaction saved, a bank sync, the partner's change
///   arriving from iCloud).
/// - Sunday check-in: every Sunday at 6 PM.
///
/// Everything is worked out here from the budget; nothing goes through a server.
@MainActor
enum Reminders {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "reminders")
    private static let center = UNUserNotificationCenter.current()
    private static let billPrefix = "suffice.bill."
    private static let weeklyID = "suffice.weekly"
    /// The budget alerts already sent this month, so each one goes once.
    private static let sentKey = "reminders.budgetAlertsSent"
    private static var pending: Task<Void, Never>?

    static var anyOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: SettingsKey.remindBills)
            || defaults.bool(forKey: SettingsKey.remindBudgets)
            || defaults.bool(forKey: SettingsKey.remindWeekly)
    }

    /// At launch: show reminders even while Suffice is open, and open the right tab on a tap.
    static func start() {
        center.delegate = ReminderDelegate.shared
    }

    /// Asks to send notifications (once; later calls return what was decided).
    @discardableResult
    static func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("Couldn't ask for notifications: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether notifications are turned off for Suffice in Settings.
    static func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    /// After saves, debounced like the widgets.
    static func schedule(_ container: ModelContainer) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await refresh(container.mainContext)
        }
    }

    /// Brings every reminder up to date with the budget.
    static func refresh(_ context: ModelContext, now: Date = .now) async {
        guard !ScreenshotMode.isOn else { return }
        let defaults = UserDefaults.standard
        await scheduleBills(context, on: defaults.bool(forKey: SettingsKey.remindBills), now: now)
        await scheduleWeekly(on: defaults.bool(forKey: SettingsKey.remindWeekly))
        if defaults.bool(forKey: SettingsKey.remindBudgets) {
            await alertBudgets(context, now: now)
        }
    }

    /// When budget alerts are turned on: budgets already past 80% this month don't alert right
    /// away; only the next ones to cross do.
    static func markBudgetsSeen(_ context: ModelContext, now: Date = .now) {
        let month = MonthSpan(containing: now)
        var sent = sentAlerts(in: month)
        for status in statuses(context, month: month) {
            if let level = level(of: status) { sent.insert(key(status, level, month)) }
        }
        UserDefaults.standard.set(Array(sent), forKey: sentKey)
    }

    // MARK: Bills

    private static func scheduleBills(_ context: ModelContext, on: Bool, now: Date) async {
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(billPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard on else { return }

        let calendar = Calendar.current
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter { $0.isActive && !$0.isAutopay }
        let payments = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.billID != nil }))) ?? []).map(\.record)
        let end = calendar.date(byAdding: .day, value: 21, to: now) ?? now
        var requests: [UNNotificationRequest] = []
        for bill in bills {
            let record = bill.record
            for due in BudgetMath.occurrences(of: record, from: now, to: end, calendar: calendar)
            where BudgetMath.payment(for: record, dueOn: due, payments: payments, calendar: calendar) == nil {
                guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: due),
                      let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore),
                      fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(bill.name) is due tomorrow"
                content.body = "\(bill.amountLabel). Tap to mark it paid once it’s done."
                content.sound = .default
                content.userInfo = ["tab": "bills"]
                content.threadIdentifier = "bills"
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let id = billPrefix + bill.id.uuidString + "." + String(Int(due.timeIntervalSince1970))
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
        }
        // iOS keeps 64 pending notifications per app; the soonest matter most.
        let soonest = requests.sorted { fireDate($0) < fireDate($1) }.prefix(40)
        for request in soonest {
            do { try await center.add(request) } catch { log.error("Couldn't schedule a bill reminder: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func fireDate(_ request: UNNotificationRequest) -> Date {
        (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
    }

    // MARK: Weekly

    private static func scheduleWeekly(on: Bool) async {
        center.removePendingNotificationRequests(withIdentifiers: [weeklyID])
        guard on else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sunday check-in"
        content.body = "See what you spent this week and what’s left for the month."
        content.sound = .default
        content.userInfo = ["tab": "budget"]
        var parts = DateComponents()
        parts.weekday = 1
        parts.hour = 18
        let request = UNNotificationRequest(identifier: weeklyID, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true))
        do { try await center.add(request) } catch { log.error("Couldn't schedule the check-in: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Budgets

    private enum Level: String { case low, over }

    private static func level(of status: CategoryStatus) -> Level? {
        guard status.limitCents > 0 else { return nil }
        if status.spentCents > status.limitCents { return .over }
        if status.progress >= 0.8 { return .low }
        return nil
    }

    private static func key(_ status: CategoryStatus, _ level: Level, _ month: MonthSpan) -> String {
        "\(Int(month.start.timeIntervalSince1970)).\(status.id.uuidString).\(level.rawValue)"
    }

    /// This month's alerts already sent; older months' drop off.
    private static func sentAlerts(in month: MonthSpan) -> Set<String> {
        let prefix = "\(Int(month.start.timeIntervalSince1970))."
        return Set((UserDefaults.standard.stringArray(forKey: sentKey) ?? []).filter { $0.hasPrefix(prefix) })
    }

    private static func statuses(_ context: ModelContext, month: MonthSpan) -> [CategoryStatus] {
        let categories = ((try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []).map(\.record)
        let entries = Persistence.entries(in: month, context: context).map(\.record)
        return BudgetMath.statuses(categories, entries: entries, in: month)
    }

    private static func alertBudgets(_ context: ModelContext, now: Date) async {
        let month = MonthSpan(containing: now)
        var sent = sentAlerts(in: month)
        let names = Dictionary(((try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let calendar = Calendar.current
        let daysLeft = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: month.end).day ?? 1))
        let monthName = month.start.formatted(.dateTime.month(.wide))

        for status in statuses(context, month: month) {
            guard let level = level(of: status) else { continue }
            let id = key(status, level, month)
            guard !sent.contains(id) else { continue }
            // Going over also counts as having passed 80%.
            if level == .over { sent.insert(key(status, .low, month)) }
            sent.insert(id)
            // Saved before sending, so a refresh running alongside doesn't send it too.
            UserDefaults.standard.set(Array(sent), forKey: sentKey)
            let name = names[status.id] ?? status.category.name
            let content = UNMutableNotificationContent()
            switch level {
            case .low:
                content.title = "\(name) is at \(Int((status.progress * 100).rounded(.down)))%"
                content.body = "\(Money.whole(status.leftCents)) left for the next \(daysLeft == 1 ? "day" : "\(daysLeft) days")."
            case .over:
                content.title = "\(name) is over budget"
                content.body = "\(Money.whole(-status.leftCents)) over for \(monthName). Move money from another budget, or adjust the plan."
            }
            content.sound = .default
            content.userInfo = ["tab": "budget"]
            content.threadIdentifier = "budgets"
            do {
                try await center.add(UNNotificationRequest(identifier: "suffice.budget." + id, content: content, trigger: nil))
            } catch {
                log.error("Couldn't send a budget alert: \(error.localizedDescription, privacy: .public)")
            }
        }
        UserDefaults.standard.set(Array(sent), forKey: sentKey)
    }
}

/// Shows reminders while the app is open, and opens Bills or Budget when one is tapped.
nonisolated final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderDelegate()

    // Completion-handler forms: they must be called on the main thread, which an async
    // delegate method doesn't promise (that crashed Caloma whenever a notification was tapped).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        let done = MainThreadCompletion<Void> { _ in completionHandler() }
        DispatchQueue.main.async {
            defer { done.run(()) }
            MainActor.assumeIsolated {
            let router = AppRouter.shared
            switch tab {
            case "bills": router.tab = .bills
            case "budget": router.tab = .budget
            default: router.tab = .overview
            }
            router.showThisMonth()
            }
        }
    }
}

/// A notification delegate's completion handler, carried to the main queue to be called there.
private nonisolated final class MainThreadCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func run(_ value: Value) { completion(value) }
}

