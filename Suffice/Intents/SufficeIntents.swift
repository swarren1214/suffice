import AppIntents
import Foundation
import SwiftData

// Siri, Shortcuts and Spotlight. Every action works without opening the app and reads or
// writes the same store the app uses (Persistence.shared), so changes sync to the household
// like any other.

// MARK: - Entities

/// A budget or subcategory, for "How much is left in Dining Out?" and logging spending.
nonisolated struct BudgetIntentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Budget")
    static let defaultQuery = BudgetIntentQuery()

    let id: UUID
    let name: String
    let symbol: String
    /// The budget it's in, for a subcategory.
    let parentName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: parentName.map { "in \($0)" },
            image: .init(systemName: symbol)
        )
    }
}

nonisolated struct BudgetIntentQuery: EnumerableEntityQuery {
    @MainActor
    func allEntities() async throws -> [BudgetIntentEntity] {
        let categories = (try? Persistence.shared.mainContext.fetch(FetchDescriptor<BudgetCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let active = categories.filter { !$0.isArchived }
        let names = Dictionary(active.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Budgets first, each followed by its subcategories.
        let parents = active.filter { $0.parentID == nil }
        return parents.flatMap { parent in
            [BudgetIntentEntity(id: parent.id, name: parent.name, symbol: parent.symbol, parentName: nil)]
                + active.filter { $0.parentID == parent.id }.map {
                    BudgetIntentEntity(id: $0.id, name: $0.name, symbol: $0.symbol, parentName: names[parent.id])
                }
        }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BudgetIntentEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BudgetIntentEntity] {
        try await allEntities()
    }
}

/// A bill, for "Mark the electric bill paid".
nonisolated struct BillIntentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bill")
    static let defaultQuery = BillIntentQuery()

    let id: UUID
    let name: String
    let amount: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(amount)", image: .init(systemName: "calendar"))
    }
}

nonisolated struct BillIntentQuery: EnumerableEntityQuery {
    @MainActor
    func allEntities() async throws -> [BillIntentEntity] {
        let bills = (try? Persistence.shared.mainContext.fetch(FetchDescriptor<Bill>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return bills.filter(\.isActive).map { BillIntentEntity(id: $0.id, name: $0.name, amount: $0.amountLabel) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BillIntentEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BillIntentEntity] {
        try await allEntities()
    }
}

// MARK: - How much is left

nonisolated struct BudgetLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Check What's Left"
    static let description = IntentDescription("Hear how much is left in a budget this month, or in all of them.")

    @Parameter(title: "Budget", description: "Leave empty for every budget together.")
    var budget: BudgetIntentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check what's left in \(\.$budget)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let data = AskData(container: Persistence.shared)
        let month = MonthSpan(containing: .now)
        let days = AskData.daysLeft
        let togo = days == 1 ? "with today left" : "with \(days) days to go"

        if let budget {
            guard let status = data.status(of: budget.id, in: month) else {
                return .result(value: 0, dialog: "\(budget.name) has nothing planned or spent this month.")
            }
            guard status.limitCents > 0 else {
                return .result(value: -status.spentCents, dialog: "You've spent \(Money.text(status.spentCents)) on \(budget.name) this month. It doesn't have a monthly amount.")
            }
            if status.leftCents >= 0 {
                return .result(value: status.leftCents, dialog: "You have \(Money.text(status.leftCents)) left in \(budget.name), \(togo).")
            }
            return .result(value: status.leftCents, dialog: "\(budget.name) is \(Money.text(-status.leftCents)) over this month.")
        }

        // Every budget together.
        let planned = data.statuses(in: month).filter { $0.limitCents > 0 }
        // This month's stash amounts are planned too, so they come out of what's left.
        let left = planned.reduce(0) { $0 + $1.leftCents } - data.stashed(in: month)
        let over = planned.filter(\.isOver).map(\.category.name)
        var dialog = left >= 0
            ? "You have \(Money.text(left)) left to spend this month, \(togo)."
            : "You're \(Money.text(-left)) over budget this month."
        if over.count == 1 {
            dialog += " \(over[0]) is over."
        } else if over.count > 1 {
            dialog += " \(over.count) budgets are over: \(over.formatted(.list(type: .and)))."
        }
        return .result(value: left, dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Log spending

nonisolated struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Spending"
    static let description = IntentDescription("Add a purchase to Suffice. It's filed under the budget you choose, or the one you always use for that place.")

    @Parameter(title: "Amount", requestValueDialog: "How much was it?")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Where", requestValueDialog: "Where did you spend it?")
    var payee: String

    @Parameter(title: "Budget")
    var budget: BudgetIntentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$payee) in \(\.$budget)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cents = Int((NSDecimalNumber(decimal: amount.amount).doubleValue * 100).rounded())
        guard cents > 0 else {
            throw $amount.needsValueError("How much was it?")
        }
        let place = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else {
            throw $payee.needsValueError("Where did you spend it?")
        }
        let context = Persistence.shared.mainContext
        // The budget they named, else the one this place always goes to, else ask.
        guard let categoryID = budget?.id ?? Ledger.ruleCategory(for: place, in: context) else {
            throw $budget.needsValueError("Which budget is it for?")
        }

        var draft = EntryDraft()
        draft.payee = place
        draft.amountCents = cents
        draft.kind = .expense
        draft.categoryID = categoryID
        draft.memberID = UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? "")
        draft.date = .now
        Ledger.add(draft, in: context)

        let data = AskData(container: Persistence.shared)
        let name = data.category(categoryID)?.name ?? "your budget"
        var dialog = "Logged \(Money.text(cents)) at \(place) in \(name)."
        if let status = data.status(of: categoryID, in: MonthSpan(containing: .now)), status.limitCents > 0 {
            dialog += status.leftCents >= 0
                ? " \(Money.text(status.leftCents)) left there this month."
                : " That's \(Money.text(-status.leftCents)) over this month."
        }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Bills

nonisolated struct BillsDueIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Bills Due"
    static let description = IntentDescription("Hear which bills are due this week and any that are late.")

    @Parameter(title: "Days Ahead", default: 7, inclusiveRange: (1, 60))
    var days: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Check bills due in the next \(\.$days) days")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let due = BillSchedule.unpaid(within: days)
        guard !due.isEmpty else {
            return .result(dialog: "Nothing's due in the next \(days) days, and nothing's late.")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let parts = due.prefix(5).map { item in
            let when: String
            if item.date < today {
                when = "late"
            } else if calendar.isDateInToday(item.date) {
                when = "today"
            } else if calendar.isDateInTomorrow(item.date) {
                when = "tomorrow"
            } else {
                when = item.date.formatted(.dateTime.weekday(.wide))
            }
            return "\(item.bill.name) \(item.bill.amountLabel) \(when)"
        }
        let total = due.reduce(0) { $0 + $1.bill.amountCents }
        let count = due.count == 1 ? "One bill is" : "\(due.count) bills are"
        var dialog = "\(count) due: \(parts.formatted(.list(type: .and)))."
        if due.count > 5 { dialog += " And \(due.count - 5) more." }
        if due.count > 1 { dialog += " \(Money.text(total)) in all." }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

nonisolated struct MarkBillPaidIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Bill Paid"
    static let description = IntentDescription("Mark the next unpaid due date of a bill as paid, for its usual amount.")

    @Parameter(title: "Bill", requestValueDialog: "Which bill?")
    var bill: BillIntentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$bill) paid")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Persistence.shared.mainContext
        guard let model = Bill.find(bill.id, in: context) else {
            return .result(dialog: "That bill isn't in Suffice anymore.")
        }
        // The earliest unpaid due date: a late one, or the next within a month.
        guard let next = BillSchedule.unpaid(within: 31).first(where: { $0.bill.id == model.id }) else {
            return .result(dialog: "\(model.name) has nothing due right now.")
        }
        let memberID = UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.currentMember) ?? "")
        Ledger.pay(model, dueOn: next.date, memberID: memberID, in: context)
        let day = next.date.formatted(.dateTime.month(.wide).day())
        return .result(dialog: "Marked \(model.name) paid, \(Money.text(model.amountCents)) for \(day).")
    }
}

/// Unpaid due dates: late ones (up to 45 days back) and those coming up.
enum BillSchedule {
    struct Due {
        let bill: Bill
        let date: Date
    }

    @MainActor
    static func unpaid(within days: Int) -> [Due] {
        let context = Persistence.shared.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: max(days, 1), to: today) ?? today
        let lateFrom = calendar.date(byAdding: .day, value: -45, to: today) ?? today
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter(\.isActive)
        let payments = ((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).filter { $0.billID != nil }.map(\.record)
        var due: [Due] = []
        for bill in bills {
            for date in BudgetMath.occurrences(of: bill.record, from: lateFrom, to: end) {
                if !BudgetMath.state(of: bill.record, dueOn: date, payments: payments).isPaid {
                    due.append(Due(bill: bill, date: date))
                }
            }
        }
        return due.sorted { $0.date < $1.date }
    }
}

// MARK: - Ask Suffice

nonisolated struct AskSufficeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Suffice"
    static let description = IntentDescription("Ask anything about your budget, bills and spending. Answered on this device.")

    @Parameter(title: "Question", requestValueDialog: "What do you want to know?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Suffice \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Ask Suffice comes with Suffice Plus or Hearth+.
        let purchases = HearthPurchases.shared
        if !purchases.isUnlocked { await purchases.refresh() }
        guard purchases.isUnlocked else {
            let message = "Ask Suffice comes with Suffice Plus or Hearth+. Open Suffice to see the plans."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let answer = await AskEngine.shared.answerOnce(question, container: Persistence.shared)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Phrases

/// What you can say to Siri without setting anything up. Every phrase names the app.
nonisolated struct SufficeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BudgetLeftIntent(),
            phrases: [
                "How much is left in \(\.$budget) in \(.applicationName)",
                "What's left in \(\.$budget) in \(.applicationName)",
                "How much is left in \(.applicationName)",
                "How much can I spend in \(.applicationName)",
                "Check my budget in \(.applicationName)",
            ],
            shortTitle: "What's Left",
            systemImageName: "chart.pie"
        )
        AppShortcut(
            intent: LogTransactionIntent(),
            phrases: [
                "Log spending in \(.applicationName)",
                "Log a purchase in \(.applicationName)",
                "Add a transaction in \(.applicationName)",
                "Log \(\.$budget) spending in \(.applicationName)",
            ],
            shortTitle: "Log Spending",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: BillsDueIntent(),
            phrases: [
                "What bills are due in \(.applicationName)",
                "What's due this week in \(.applicationName)",
                "Check my bills in \(.applicationName)",
            ],
            shortTitle: "Bills Due",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: MarkBillPaidIntent(),
            phrases: [
                "Mark \(\.$bill) paid in \(.applicationName)",
                "I paid \(\.$bill) in \(.applicationName)",
                "Mark a bill paid in \(.applicationName)",
            ],
            shortTitle: "Mark Bill Paid",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: AskSufficeIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Suffice",
            systemImageName: "sparkles"
        )
    }
}
