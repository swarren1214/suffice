import SwiftData
import SwiftUI
import UIKit

@main
struct SufficeApp: App {
    @UIApplicationDelegateAdaptor(SufficeAppDelegate.self) private var appDelegate
    @State private var router = AppRouter.shared
    @State private var lock = AppLock.shared
    private let container: ModelContainer

    init() {
        ScreenshotMode.prepareLaunch()
        let container = Persistence.shared
        self.container = container
        if ScreenshotMode.isOn {
            // The demo household is seeded by RootTabView's screenshot stage; nothing syncs.
            HouseholdSync.shared.startForScreenshots()
        } else {
            StarterData.seedIfNeeded(in: container.mainContext)
            // Fold together anything two devices both made.
            SyncCleanup.mergeDuplicates(in: container.mainContext)
            // Count the 1st for stashes that count on their own.
            StashScheduler.run(in: container.mainContext)
            // The budget syncs in the Hearth household's iCloud: its zone registers with the
            // household before the household starts (AppRoot's task).
            HouseholdSync.shared.start(container)
        }
        // Alerts use the system label color rather than the brand green. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        // Switches use the designs' bright green.
        UISwitch.appearance().onTintColor = UIColor(Brand.greenBright)
        AppLock.shared.lockIfEnabled()
        // Keep the widgets current: every save rewrites their snapshot (debounced).
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                WidgetSync.schedule(container)
                Reminders.schedule(container)
                // The other Hearth apps get the household's names and photos.
                HearthHousehold.schedule(container)
            }
        }
        WatchSync.shared.start()
        Reminders.start()
        WidgetSync.refresh(container.mainContext)
        // One sign-in for every Hearth app: follow sign-ins and sign-outs in BigTable and Sated.
        HearthSignIn.start()
        // Suffice Plus and Hearth+ (RevenueCat). Screenshots show everything unlocked; nothing
        // is set up until the real key is in AppConfig.
        if ScreenshotMode.isOn { HearthPurchases.shared.previewUnlocked = true }
        if AppConfig.revenueCatAPIKey != AppConfig.revenueCatPlaceholder {
            HearthPurchases.shared.configure(
                app: .suffice,
                apiKey: AppConfig.revenueCatAPIKey,
                apiBaseURL: AppConfig.apiBaseURL,
                accessToken: {
                    // Household plans need a real account; the anonymous session doesn't count.
                    guard await HearthAPI.shared.isSignedInWithApple else { return nil }
                    return try? await HearthAPI.shared.accessToken()
                },
                signInButton: { AnyView(ProfileAppleButton()) }
            )
        }
        HearthHousehold.start(container)
        // Siri learns the current budget and bill names for its phrases.
        SufficeShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .background(KeyboardDismissal().frame(width: 0, height: 0))
                .task { if !ScreenshotMode.isOn { await HearthAPI.shared.prepareSession() } }
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
            Button("Ask Suffice") { router.showsAsk = true }.keyboardShortcut("k")
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
    /// Ask Suffice is open (the ✨ button, or ⌘K).
    var showsAsk = false

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

    /// A bill shared or opened in Suffice; Bills reads it and clears it.
    var incomingDocument: IncomingDocument?

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
    /// The budget's sync (the Hearth container's Budget zone).
    @State private var household = HouseholdSync.shared
    /// The Hearth household: the same family in every Hearth app. Suffice always has one.
    @State private var family = HearthHouseholdStore.shared
    @State private var purchases = HearthPurchases.shared

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
        // Joined a family's household and its budget arrived: say what happened to this one.
        .alert("You’re in the Family Budget", isPresented: $household.showsJoinedNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You share one budget with \(family.ownerName ?? "your family") and see every change. The budget on this \(DeviceName.current) is replaced by the shared one. Yours stays in your iCloud and comes back if you leave.")
        }
        .overlay {
            if household.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: .rect(cornerRadius: 20))
            }
        }
        // Hearth household invitations (the one invite for everything, the budget included),
        // and keeping Suffice's people in step with the household.
        .hearthHouseholdInvitations()
        // Suffice always works inside a household (a household of one is fine).
        .hearthHouseholdRequired(isActive: onboarded && !ScreenshotMode.isOn, accent: Brand.green)
        // Suffice's side of a person's page in Household.
        .environment(\.hearthPersonExtras, { person in AnyView(SufficePersonExtras(person: person)) })
        .task {
            guard !ScreenshotMode.isOn else { return }
            family.start(app: .suffice)
            household.householdDidStart()
            SufficeHearthHousehold.sync(in: context)
        }
        .onChange(of: family.snapshot) { SufficeHearthHousehold.sync(in: context) }
        // The family's budget finished arriving: mirror its people now.
        .onChange(of: household.isSettled) { _, settled in
            if settled { SufficeHearthHousehold.sync(in: context) }
        }
        // Share the budget with the household's adults, or join the family's.
        .onChange(of: family.mode) { Task { await household.updateSharing() } }
        .onChange(of: family.exists) { Task { await household.updateSharing() } }
        .onChange(of: family.participants.count) { Task { await household.updateSharing() } }
        .onChange(of: family.info?.appShareURLs) { Task { await household.updateSharing() } }
        // Just got the plan (bought, restored, or the household's): connected banks catch up.
        .onChange(of: purchases.isUnlocked) { _, unlocked in
            guard unlocked, !ScreenshotMode.isOn else { return }
            Task {
                await BankSync.syncAllIfStale(
                    memberID: UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? ""),
                    in: context
                )
            }
        }
        // Just got Hearth+: allowance Caloma paid out comes in to review.
        .onChange(of: purchases.hasHearthPlus) { _, has in
            if has { CalomaAllowance.importPayouts(in: context) }
        }
        // Widgets open suffice://overview, suffice://budget or suffice://bills.
        .onOpenURL { url in
            // A PDF or photo opened in Suffice (Share › Suffice, Open in Suffice): read it as a bill.
            if url.isFileURL {
                guard let document = IncomingDocument.load(url) else { return }
                router.tab = .bills
                router.showThisMonth()
                router.incomingDocument = document
                return
            }
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
                // A new month owes stashes their 1st.
                if !ScreenshotMode.isOn { StashScheduler.run(in: context) }
                // A new day changes which bills are due and late.
                WidgetSync.refresh(context)
                Task {
                    await household.syncNow()
                    await household.updateSharing()
                }
                Task { await HearthSignIn.follow() }
                HearthHousehold.publish(in: context)
                SufficeHearthHousehold.sync(in: context)
                // Allowance Caloma paid out, as expenses to review.
                CalomaAllowance.importPayouts(in: context)
                Task { await Reminders.refresh(context) }
                // Connected banks, at most hourly.
                Task {
                    await BankSync.syncAllIfStale(
                        memberID: UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? ""),
                        in: context
                    )
                    // Then receipts and bills from email, matched to what the bank just sent.
                    await ReceiptScanner.shared.scanIfStale(in: context)
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
