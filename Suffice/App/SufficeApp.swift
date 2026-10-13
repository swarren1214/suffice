import SwiftData
import SwiftUI
import UIKit

@main
struct SufficeApp: App {
    @State private var router = AppRouter.shared
    @State private var lock = AppLock.shared
    private let container: ModelContainer

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        StarterData.seedIfNeeded(in: container.mainContext)
        Household.mergeDuplicateMembers(in: container.mainContext)
        // Alerts use the system label color rather than the brand green. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        // Switches use the designs' bright green.
        UISwitch.appearance().onTintColor = UIColor(Brand.greenBright)
        AppLock.shared.lockIfEnabled()
        // Keep the widgets current: every save rewrites their snapshot (debounced).
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WidgetSync.schedule(container) }
        }
        WidgetSync.refresh(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .task { await LifestyleAPI.shared.prepareSession() }
                .environment(router)
                .environment(lock)
        }
        .modelContainer(container)
        .commands { SufficeCommands(router: router) }
    }
}

/// Keyboard shortcuts for iPad (hold ⌘ to see them): new transaction, the tabs, and months.
struct SufficeCommands: Commands {
    let router: AppRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Transaction") {
                router.tab = .activity
                router.wantsNewTransaction = true
            }
            .keyboardShortcut("n")
        }
        CommandMenu("Go") {
            Button("Overview") { router.tab = .overview }.keyboardShortcut("1")
            Button("Activity") { router.tab = .activity }.keyboardShortcut("2")
            Button("Budget") { router.tab = .budget }.keyboardShortcut("3")
            Button("Bills") { router.tab = .bills }.keyboardShortcut("4")
            Button("Search") { router.tab = .search }.keyboardShortcut("f")
            Divider()
            Button("Previous Month") { router.showPreviousMonth() }.keyboardShortcut("[")
            Button("Next Month") { router.showNextMonth() }
                .keyboardShortcut("]")
                .disabled(router.isThisMonth)
            Button("This Month") { router.showThisMonth() }
                .keyboardShortcut("t")
                .disabled(router.isThisMonth)
        }
    }
}

/// Which tab is showing and which month every tab shows.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .overview

    /// The month Overview, Activity, Budget and Bills show. Never later than this month.
    var month = MonthSpan(containing: .now)
    @ObservationIgnored private var lastThisMonth = MonthSpan(containing: .now)
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?

    init() {
        // A new month while the app is open: someone looking at this month moves to the new one.
        dayChangeObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollOverIfNeeded() }
        }
    }

    /// Also called when the app comes back to the foreground.
    func rollOverIfNeeded() {
        let now = MonthSpan(containing: .now)
        guard now != lastThisMonth else { return }
        if month == lastThisMonth { month = now }
        lastThisMonth = now
    }

    var isThisMonth: Bool { month == MonthSpan(containing: .now) }

    func showThisMonth() { month = MonthSpan(containing: .now) }

    func showPreviousMonth() { month = month.offset(by: -1) }

    /// Never past this month.
    func showNextMonth() {
        let next = month.offset(by: 1)
        if next.start <= MonthSpan(containing: .now).start { month = next }
    }

    /// Set by ⌘N; Activity opens a new transaction and clears it.
    var wantsNewTransaction = false

    /// When a new transaction happens: now, or, while an earlier month is showing, today's
    /// day-of-month in that month (at noon), so back-filling last month lands in last month.
    var entryDate: Date {
        guard !isThisMonth else { return .now }
        let calendar = Calendar.current
        let day = calendar.component(.day, from: .now)
        let date = month.dueDate(day: day, calendar: calendar)
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }
}

/// Onboarding the first time, the tabs after that, and the Face ID cover when locked.
struct AppRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(AppLock.self) private var lock
    @AppStorage(SettingsKey.onboarded) private var onboarded = false

    var body: some View {
        Group {
            if onboarded {
                RootTabView()
            } else {
                OnboardingView()
            }
        }
        .tint(Brand.green)
        .animation(.smooth, value: onboarded)
        // Widgets open suffice://overview, suffice://budget or suffice://bills.
        .onOpenURL { url in
            guard url.scheme == WidgetLink.scheme else { return }
            switch url.host() {
            case "budget": router.tab = .budget
            case "bills": router.tab = .bills
            case "activity": router.tab = .activity
            default: router.tab = .overview
            }
            router.showThisMonth()
        }
        // The lock cover gets its own window, so it hides open sheets too.
        .onChange(of: lock.isLocked, initial: true) { _, locked in
            if locked {
                LockWindow.show(lock: lock)
            } else {
                LockWindow.hide()
            }
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .active:
                router.rollOverIfNeeded()
                // A new day changes which bills are due and late.
                WidgetSync.refresh(context)
                // Connected banks, at most hourly.
                Task {
                    await BankSync.syncAllIfStale(
                        memberID: UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? ""),
                        in: context
                    )
                }
                // Only when coming back from the background: the Face ID prompt itself
                // passes through inactive, and cancelling it shouldn't bring it back.
                if old == .background {
                    Task { await lock.unlock() }
                }
            case .background:
                lock.lockIfEnabled()
                WidgetSync.refresh(context)
            default:
                break
            }
        }
    }
}
