import SwiftData
import SwiftUI

/// Screenshot mode, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, Suffice runs on an in-memory store filled with a demo
/// household, skips onboarding, the Face ID lock, household sync, bank sync and the API, and
/// looks signed in with iCloud up to date. Adding `-Screen <name>` opens one screen (see
/// `Screen`). Debug builds only: Release ignores the arguments, so none of this can be reached
/// in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`.
    nonisolated enum Screen: String, CaseIterable {
        case overview, budget, budgetdetail, activity, transaction, bills, ask, voice, askhome, profile, household
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// Where the real values of the settings below wait while screenshot mode borrows them.
    private static let savedSettingsKey = "screenshots.savedSettings"
    /// The settings screenshot mode changes. "budget.joinedOwner" is HouseholdSync's
    /// (`HouseholdSync.joinedOwnerKey`).
    private static let borrowedKeys = [
        SettingsKey.onboarded, SettingsKey.faceIDLock, SettingsKey.appleUserID, SettingsKey.currentMember, "budget.joinedOwner",
    ]

    /// At launch, before anything reads them: the settings that would otherwise show onboarding,
    /// the lock or someone else's household. The real ones are put back on the next normal
    /// launch, so the Simulator's own budget comes back as it was.
    @MainActor
    static func prepareLaunch() {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard isOn else {
            if let saved = defaults.dictionary(forKey: savedSettingsKey) {
                for key in borrowedKeys { defaults.set(saved[key], forKey: key) }
                defaults.removeObject(forKey: savedSettingsKey)
            }
            return
        }
        // Saved once: a second screenshot launch mustn't save the demo values over them.
        if defaults.dictionary(forKey: savedSettingsKey) == nil {
            var saved: [String: Any] = [:]
            for key in borrowedKeys {
                if let value = defaults.object(forKey: key) { saved[key] = value }
            }
            defaults.set(saved, forKey: savedSettingsKey)
        }
        defaults.set(true, forKey: SettingsKey.onboarded)
        defaults.set(false, forKey: SettingsKey.faceIDLock)
        defaults.set("screenshots-demo", forKey: SettingsKey.appleUserID)
        defaults.removeObject(forKey: "budget.joinedOwner")
        // SettingsKey.currentMember is set to the demo person when the household is seeded.
        #endif
    }
}

/// Screens pushed only in screenshot mode (the app reaches them through inline links).
enum ScreenshotRoute: Hashable {
    case profile
    case household
}

extension View {
    /// Destinations for `ScreenshotRoute`, added to the Overview tab's root view.
    func screenshotDestinations() -> some View {
        navigationDestination(for: ScreenshotRoute.self) { route in
            switch route {
            case .profile: ProfileView()
            case .household: HearthHouseholdView(accent: Brand.green)
            }
        }
    }

    /// Screenshot mode: fills the store with the demo household, then opens the requested
    /// screen. Does nothing otherwise.
    func screenshotStage(overviewPath: Binding<NavigationPath>) -> some View {
        modifier(ScreenshotStage(overviewPath: overviewPath))
    }
}

private struct ScreenshotStage: ViewModifier {
    @Binding var overviewPath: NavigationPath

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @State private var entry: LedgerEntry?
    @State private var budget: BudgetCategory?
    @State private var showsVoice = false

    func body(content view: Content) -> some View {
        if ScreenshotMode.isOn {
            view
                .task { await stage() }
                .sheet(item: $entry) { TransactionSheet(entry: $0) }
                .sheet(item: $budget) { BudgetSheet(category: $0, month: MonthSpan(containing: .now)) }
                .fullScreenCover(isPresented: $showsVoice) { AskVoiceView() }
        } else {
            view
        }
    }

    private func stage() async {
        ScreenshotSeed.seed(context: modelContext)
        // Let the first screen settle before moving on from it.
        try? await Task.sleep(for: .milliseconds(400))
        guard let screen = ScreenshotMode.screen else { return }
        switch screen {
        case .overview:
            router.tab = .overview
        case .budget:
            router.tab = .budget
        case .budgetdetail:
            router.tab = .budget
            budget = ScreenshotSeed.food
        case .activity:
            router.tab = .activity
        case .transaction:
            router.tab = .activity
            entry = ScreenshotSeed.featuredEntry
        case .bills:
            router.tab = .bills
        case .ask:
            router.tab = .budget
            ScreenshotSeed.showConversation(context: modelContext)
            router.showsAsk = true
        case .voice:
            router.tab = .budget
            ScreenshotSeed.showConversation(context: modelContext)
            showsVoice = true
        case .askhome:
            router.tab = .budget
            router.showsAsk = true
        case .profile:
            router.tab = .overview
            overviewPath.append(ScreenshotRoute.profile)
        case .household:
            router.tab = .overview
            overviewPath.append(ScreenshotRoute.profile)
            overviewPath.append(ScreenshotRoute.household)
        }
    }
}

// MARK: - Demo household

/// Daniel and Maya: two paychecks each month, four accounts at made-up banks, the starter
/// budgets with real amounts (plus Phone & Internet and a one-month Travel budget), the usual
/// bills paid on time, and three months and this month so far of everyday spending.
@MainActor
enum ScreenshotSeed {
    /// Opened by the budget detail screenshot.
    private(set) static var food: BudgetCategory?
    /// Opened by the transaction screenshot: this month's latest Costco run.
    private(set) static var featuredEntry: LedgerEntry?

    private static var seeded = false

    /// Something bought again and again: about `perMonth` times a month, around `cents`.
    private struct Habit {
        var payee: String
        var cents: Int
        var category: String
        var perMonth: Int
        var byPartner: Bool
        var onCard: Bool
    }

    private static let habits: [Habit] = [
        Habit(payee: "Costco", cents: 212_40, category: "Food/Groceries", perMonth: 2, byPartner: true, onCard: true),
        Habit(payee: "Fresh Market", cents: 84_75, category: "Food/Groceries", perMonth: 3, byPartner: false, onCard: false),
        Habit(payee: "Sunrise Grocers", cents: 56_30, category: "Food/Groceries", perMonth: 3, byPartner: true, onCard: false),
        Habit(payee: "Brew & Bean Coffee", cents: 6_45, category: "Food/Fast food", perMonth: 8, byPartner: false, onCard: true),
        Habit(payee: "Burger Barn", cents: 14_20, category: "Food/Fast food", perMonth: 3, byPartner: true, onCard: true),
        Habit(payee: "Taco Fiesta", cents: 23_60, category: "Food/Fast food", perMonth: 2, byPartner: false, onCard: true),
        Habit(payee: "QuickFuel", cents: 47_80, category: "Auto/Gas", perMonth: 4, byPartner: false, onCard: true),
        Habit(payee: "Builders Supply", cents: 64_90, category: "Home/Home improvements", perMonth: 1, byPartner: false, onCard: false),
        Habit(payee: "Hardware Hub", cents: 31_75, category: "Home/Home improvements", perMonth: 1, byPartner: false, onCard: true),
        Habit(payee: "Cinema 8", cents: 31_50, category: "Entertainment/Date night", perMonth: 1, byPartner: true, onCard: true),
        Habit(payee: "Olive & Vine", cents: 86_40, category: "Entertainment/Date night", perMonth: 1, byPartner: false, onCard: true),
        Habit(payee: "Lucky Lanes", cents: 42_00, category: "Entertainment/Date night", perMonth: 1, byPartner: true, onCard: true),
        Habit(payee: "Community Food Bank", cents: 150_00, category: "Giving", perMonth: 1, byPartner: false, onCard: false),
        Habit(payee: "Hope Shelter", cents: 75_00, category: "Giving", perMonth: 1, byPartner: true, onCard: false),
    ]

    static func seed(context: ModelContext) {
        guard ScreenshotMode.isOn, !seeded else { return }
        seeded = true
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.component(.day, from: now)
        let startOfToday = calendar.startOfDay(for: now)
        let thisMonth = MonthSpan(containing: now, calendar: calendar)

        // People
        let me = Member(name: "Daniel", color: .green, sortOrder: 0)
        let partner = Member(name: "Maya", color: .purple, sortOrder: 1)
        context.insert(me)
        context.insert(partner)
        UserDefaults.standard.set(me.id.uuidString, forKey: SettingsKey.currentMember)

        // Accounts. Balances are "now", so nothing adjusts them.
        let checking = Account(institution: "Evergreen Bank", name: "Checking", mask: "4821", kind: .checking, source: .plaid, balanceCents: 6_482_17, colorHex: 0x1F6F4A, sortOrder: 0)
        let savings = Account(institution: "Evergreen Bank", name: "Savings", mask: "7730", kind: .savings, source: .plaid, balanceCents: 18_250_00, colorHex: 0x1F6F4A, sortOrder: 1)
        let joint = Account(institution: "Harbor Credit Union", name: "Joint Checking", mask: "1964", kind: .checking, balanceCents: 2_315_40, colorHex: 0x2B4C9B, sortOrder: 2)
        let card = Account(institution: "Cedar Card", name: "Rewards Card", mask: "3307", kind: .credit, balanceCents: 846_22, colorHex: 0x2E2E33, sortOrder: 3)
        for account in [checking, savings, joint, card] {
            account.balanceDate = .distantFuture
            context.insert(account)
        }

        // Budgets: the starter set, with amounts.
        var budgets = StarterData.insertBudgets(into: context, amounts: [
            "Home/Mortgage": 1_985_00, "Home/Home improvements": 250_00,
            "Auto/Gas": 220_00, "Auto/Insurance": 164_00,
            "Food/Groceries": 850_00, "Food/Fast food": 160_00,
            "Utilities/Power": 140_00, "Utilities/Gas": 90_00,
            "Entertainment/Streaming": 45_00, "Entertainment/Date night": 200_00,
            "Giving": 250_00,
        ])
        if let utilities = budgets["Utilities"] {
            let phone = BudgetCategory(name: "Phone & Internet", symbol: utilities.symbol, color: utilities.color, limitCents: 215_00, parentID: utilities.id, sortOrder: 2)
            context.insert(phone)
            budgets["Utilities/Phone & Internet"] = phone
        }
        let travel = BudgetCategory(name: "Travel", symbol: "airplane", color: .teal, limitCents: 300_00, startMonth: thisMonth.start, repeatsMonthly: false, sortOrder: StarterData.budgets.count)
        context.insert(travel)
        budgets["Travel"] = travel
        food = budgets["Food"]
        let categoryID: (String) -> UUID? = { budgets[$0]?.id }

        // The same "random" amounts every run, so screenshots match from one run to the next.
        var state: UInt64 = 0x5EED_CAFE_F00D
        func wobble(_ cents: Int, by spread: Double = 0.18) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            return max(1, Int((Double(cents) * (1 + (unit * 2 - 1) * spread)).rounded()))
        }
        func at(_ month: MonthSpan, day: Int, hour: Int) -> Date {
            let date = month.dueDate(day: day, calendar: calendar)
            return calendar.date(bySettingHour: hour, minute: (day * 7) % 60, second: 0, of: date) ?? date
        }
        var inserted: [LedgerEntry] = []
        func add(_ payee: String, _ cents: Int, _ category: UUID?, on date: Date, by person: Member, from account: Account,
                 kind: EntryKind = .expense, reviewed: Bool = true) {
            guard date <= now else { return }
            let entry = LedgerEntry(date: date, payee: payee, amountCents: cents, kind: kind, categoryID: category,
                                    memberID: person.id, accountID: account.id, isReviewed: reviewed)
            context.insert(entry)
            inserted.append(entry)
        }

        // Bills, due around today so the week strip has some coming up.
        func dueDay(_ offset: Int) -> Int { min(max(today + offset, 1), 28) }
        let mortgage = Bill(name: "Mortgage", amountCents: 1_985_00, dueDay: 1, color: .orange, categoryID: categoryID("Home/Mortgage"), isAutopay: true)
        let insurance = Bill(name: "Summit Auto Insurance", amountCents: 164_00, dueDay: dueDay(-6), color: .blue, categoryID: categoryID("Auto/Insurance"), isAutopay: true)
        let power = Bill(name: "Valley Power", amountCents: 128_44, dueDay: dueDay(3), color: .yellow, categoryID: categoryID("Utilities/Power"))
        power.isVariable = true
        power.minCents = 95_00
        power.maxCents = 170_00
        let gas = Bill(name: "Mountain Gas Co.", amountCents: 61_80, dueDay: dueDay(-3), color: .red, categoryID: categoryID("Utilities/Gas"))
        gas.isVariable = true
        gas.minCents = 35_00
        gas.maxCents = 110_00
        let phone = Bill(name: "Brightline Wireless", amountCents: 142_00, dueDay: dueDay(1), color: .pink, categoryID: categoryID("Utilities/Phone & Internet"), isAutopay: true)
        let internet = Bill(name: "Fiberlink Internet", amountCents: 73_00, dueDay: dueDay(5), color: .purple, categoryID: categoryID("Utilities/Phone & Internet"), isAutopay: true)
        let streaming = Bill(name: "StreamBox", amountCents: 15_49, dueDay: dueDay(2), color: .red, categoryID: categoryID("Entertainment/Streaming"), isAutopay: true, isSubscription: true)
        let music = Bill(name: "TuneStream Family", amountCents: 16_99, dueDay: dueDay(-9), color: .green, categoryID: categoryID("Entertainment/Streaming"), isAutopay: true, isSubscription: true)
        let storage = Bill(name: "CloudDrive 2 TB", amountCents: 9_99, dueDay: dueDay(11), color: .blue, categoryID: categoryID("Entertainment/Streaming"), isAutopay: true, isSubscription: true)
        let registration = Bill(name: "Car Registration", amountCents: 186_00, dueDay: 20, color: .teal, categoryID: categoryID("Auto"))
        registration.frequency = .yearly
        registration.startDate = thisMonth.offset(by: 4, calendar: calendar).dueDate(day: 20, calendar: calendar)
        let bills = [mortgage, insurance, power, gas, phone, internet, streaming, music, storage, registration]
        for bill in bills { context.insert(bill) }

        for monthsAgo in (0...3).reversed() {
            let month = thisMonth.offset(by: -monthsAgo, calendar: calendar)
            let days = month.days(calendar: calendar)

            // Paychecks.
            for day in [1, 15] { add("Northwind Payroll", 2_480_00, nil, on: at(month, day: day, hour: 6), by: me, from: checking, kind: .income) }
            for day in [7, 21] { add("Lakeside Clinic", 1_365_00, nil, on: at(month, day: day, hour: 6), by: partner, from: joint, kind: .income) }

            // Every bill that came due before today, paid on its due date.
            for bill in bills {
                for due in BudgetMath.occurrences(of: bill.record, from: month.start, to: month.end, calendar: calendar) where due < startOfToday {
                    let cents = bill.isVariable ? wobble(bill.amountCents, by: 0.15) : bill.amountCents
                    let account = bill.id == mortgage.id ? checking : joint
                    let date = calendar.date(bySettingHour: 9, minute: 12, second: 0, of: due) ?? due
                    guard date <= now else { continue }
                    let entry = LedgerEntry(date: date, payee: bill.name, amountCents: cents, categoryID: bill.categoryID,
                                            memberID: (bill.isAutopay ? me : partner).id, accountID: account.id, billID: bill.id)
                    entry.billDueDate = calendar.startOfDay(for: due)
                    context.insert(entry)
                }
            }

            // Everyday spending, spread through the month.
            for (index, habit) in habits.enumerated() {
                for time in 0..<habit.perMonth {
                    let spot = Int((Double(time) + 0.5) * Double(days) / Double(habit.perMonth))
                    let day = min(max(spot + 1 + index % 3 - 1, 1), days)
                    let hour = 9 + (index * 3 + time * 5) % 10
                    let person = habit.byPartner ? partner : me
                    let account = habit.onCard ? card : (habit.byPartner ? joint : checking)
                    let cents = habit.category == "Giving" ? habit.cents : wobble(habit.cents)
                    add(habit.payee, cents, categoryID(habit.category), on: at(month, day: day, hour: hour), by: person, from: account)
                }
            }
        }

        // This month: the trip, and a few that came in on their own and still need a look.
        add("SkyHigh Airlines", 286_40, categoryID("Travel"), on: at(thisMonth, day: max(today - 4, 1), hour: 21), by: me, from: card)
        add("Brew & Bean Coffee", 5_75, categoryID("Food/Fast food"), on: at(thisMonth, day: max(today - 2, 1), hour: 8), by: me, from: card, reviewed: false)
        add("Shopwise Online", 34_99, nil, on: at(thisMonth, day: max(today - 1, 1), hour: 13), by: partner, from: card, reviewed: false)
        add("Corner Pharmacy", 18_40, nil, on: at(thisMonth, day: today, hour: 8), by: me, from: card, reviewed: false)

        // "Always use Groceries for Costco".
        context.insert(PayeeRule(payee: "Costco", categoryID: categoryID("Food/Groceries")))

        let thisMonths = inserted.filter { thisMonth.contains($0.date) && $0.kind == .expense }
        featuredEntry = thisMonths.filter { $0.payee == "Costco" }.max { $0.date < $1.date }
            ?? thisMonths.filter { $0.categoryID != nil }.max { $0.date < $1.date }
        featuredEntry?.note = "Weekly groceries, plus snacks for Saturday’s game"
        try? context.save()
    }

    /// The Ask conversation in the screenshots: what's left for groceries (with its budget card),
    /// where the money went (with the breakdown), and a move between budgets waiting for Move.
    /// Every figure comes from the demo data, as the model's tools would read it.
    static func showConversation(context: ModelContext) {
        let engine = AskEngine.shared
        engine.attach(context.container)
        guard let data = engine.data else { return }
        let calendar = Calendar.current
        let month = MonthSpan(containing: .now, calendar: calendar)
        var messages: [AskMessage] = []

        if let groceries = data.findCategory("Groceries"), let status = data.status(of: groceries.id, in: month) {
            let elapsed = Double(calendar.component(.day, from: .now)) / Double(month.days(calendar: calendar))
            let onPace = Double(status.spentCents) <= Double(status.limitCents) * elapsed * 1.05
            messages.append(AskMessage(role: .user, text: "How much is left for groceries?"))
            var answer = AskMessage(role: .assistant, text: "You have **\(Money.whole(status.leftCents))** left for Groceries with \(AskData.daysLeft) days to go. "
                + (onPace ? "You’re right on pace." : "That’s a little ahead of pace, so plan the big trips."))
            answer.budgetID = groceries.id
            messages.append(answer)
        }

        let spending = data.statuses(in: month).filter { $0.spentCents > 0 }.sorted { $0.spentCents > $1.spentCents }
        if spending.count >= 2 {
            let total = spending.reduce(0) { $0 + $1.spentCents }
            messages.append(AskMessage(role: .user, text: "Where did our money go this month?"))
            var answer = AskMessage(role: .assistant, text: "You’ve spent **\(Money.whole(total))** so far this month. \(spending[0].category.name) and \(spending[1].category.name) took the most.")
            answer.breakdown = month
            messages.append(answer)
        }

        if let transfer = data.transfer(from: "Date night", to: "Groceries", dollars: 40), let amounts = data.amounts(for: transfer) {
            messages.append(AskMessage(role: .user, text: "Move $40 from date night to groceries"))
            var answer = AskMessage(role: .assistant, text: "That puts Date night at **\(Money.whole(amounts.from.1))** a month and Groceries at **\(Money.whole(amounts.to.1))**. Tap Move to confirm.")
            answer.transfer = transfer
            messages.append(answer)
        }

        engine.showScreenshotConversation(messages)
    }
}
