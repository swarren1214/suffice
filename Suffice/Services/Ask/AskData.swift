import Foundation
import SwiftData

/// Everything Ask can look up, computed from the household's own data with BudgetMath, so every
/// number it says comes from here. Nothing leaves the device.
///
/// "This month" here is always the real current month (not the month the tabs are showing),
/// since that's what people mean when they ask.
@MainActor
final class AskData {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: Snapshots

    private var categories: [BudgetCategory] {
        (try? context.fetch(FetchDescriptor<BudgetCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    private var entries: [LedgerEntry] {
        (try? context.fetch(FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }

    private var bills: [Bill] {
        ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter(\.isActive)
    }

    private var members: [Member] {
        (try? context.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    private var accounts: [Account] {
        (try? context.fetch(FetchDescriptor<Account>())) ?? []
    }

    private var stashes: [Stash] {
        ((try? context.fetch(FetchDescriptor<Stash>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []).filter { !$0.isArchived }
    }

    private var stashMoves: [StashMoveRecord] {
        ((try? context.fetch(FetchDescriptor<StashMove>())) ?? []).map(\.record)
    }

    static func month(monthsAgo: Int) -> MonthSpan {
        MonthSpan(containing: .now).offset(by: -max(monthsAgo, 0))
    }

    private static func monthName(_ month: MonthSpan) -> String {
        month == MonthSpan(containing: .now) ? "this month (\(month.start.formatted(.dateTime.month(.wide))))" : month.start.formatted(.dateTime.month(.wide).year())
    }

    /// Days left in this month, counting today: "18 days to go" on October 13th.
    static var daysLeft: Int {
        let calendar = Calendar.current
        let month = MonthSpan(containing: .now)
        return month.days(calendar: calendar) - calendar.component(.day, from: .now)
    }

    func statuses(in month: MonthSpan) -> [CategoryStatus] {
        BudgetMath.statuses(categories.map(\.record), entries: entries.map(\.record), in: month)
    }

    func status(of id: UUID, in month: MonthSpan) -> CategoryStatus? {
        let all = statuses(in: month)
        return all.first { $0.id == id } ?? all.flatMap(\.children).first { $0.id == id }
    }

    func category(_ id: UUID?) -> BudgetCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    /// A budget or subcategory by name, forgiving: exact, then starts with, then shares a word
    /// ("dining" finds Dining Out, "eating out" finds Dining Out only if a word matches).
    func findCategory(_ name: String) -> BudgetCategory? {
        let wanted = AskText.words(name)
        guard !wanted.isEmpty else { return nil }
        let candidates = categories.filter { !$0.isArchived }
        let key = wanted.joined(separator: " ")
        if let exact = candidates.first(where: { AskText.words($0.name).joined(separator: " ") == key }) { return exact }
        if let prefix = candidates.first(where: { AskText.words($0.name).joined(separator: " ").hasPrefix(key) }) { return prefix }
        let scored = candidates.map { category -> (BudgetCategory, Int) in
            let words = Set(AskText.words(category.name))
            return (category, wanted.filter { word in words.contains { $0 == word || $0.hasPrefix(word) || word.hasPrefix($0) } }.count)
        }
        // A top-level budget wins a tie with a subcategory.
        return scored.filter { $0.1 > 0 }.max { ($0.1, $0.0.parentID == nil ? 1 : 0) < ($1.1, $1.0.parentID == nil ? 1 : 0) }?.0
    }

    // MARK: Tool answers

    /// getBudgets: every budget's planned, spent and left.
    func budgetsText(monthsAgo: Int) -> String {
        let month = Self.month(monthsAgo: monthsAgo)
        let all = statuses(in: month)
        guard !all.isEmpty else { return "No budgets are set up for \(Self.monthName(month))." }
        var lines = ["Budgets for \(Self.monthName(month)):"]
        for status in all {
            lines.append(line(status))
            for child in status.children { lines.append("  - " + line(child)) }
        }
        if monthsAgo == 0 { lines.append("\(Self.daysLeft) days left in the month.") }
        return lines.joined(separator: "\n")
    }

    private func line(_ status: CategoryStatus) -> String {
        let name = status.category.name
        guard status.limitCents > 0 else { return "\(name): \(Money.text(status.spentCents)) spent, no amount planned" }
        let left = status.leftCents >= 0 ? "\(Money.text(status.leftCents)) left" : "\(Money.text(-status.leftCents)) over"
        return "\(name): \(Money.text(status.spentCents)) spent of \(Money.text(status.limitCents)), \(left) (\(Int((status.progress * 100).rounded()))%)"
    }

    /// getBudget: one budget in detail.
    func budgetText(named name: String, monthsAgo: Int) -> String {
        guard let category = findCategory(name) else {
            let names = categories.filter { $0.parentID == nil && !$0.isArchived }.map(\.name).joined(separator: ", ")
            return "No budget is called \"\(name)\". The budgets are: \(names)."
        }
        let month = Self.month(monthsAgo: monthsAgo)
        guard let status = status(of: category.id, in: month) else {
            return "\(category.name) has no amount or spending in \(Self.monthName(month))."
        }
        var lines = ["\(category.name), \(Self.monthName(month)): " + line(status)]
        if monthsAgo == 0 {
            lines.append("\(Self.daysLeft) days left in the month.")
            let calendar = Calendar.current
            let lastMonth = month.offset(by: -1)
            let samePoint = calendar.date(byAdding: .month, value: -1, to: .now) ?? lastMonth.end
            let ids = budgetIDs(category)
            let spentBefore = entries(in: category, from: lastMonth.start, to: samePoint).reduce(0) { $0 + $1.cents(in: ids) }
            lines.append("By this day last month, \(Money.text(spentBefore)) had been spent in it.")
        }
        for child in status.children { lines.append("Subcategory " + line(child)) }
        let top = topPayees(in: category, month: month)
        if !top.isEmpty {
            lines.append("Biggest payees: " + top.map { "\($0.name) \(Money.text($0.cents))\($0.count > 1 ? " (\($0.count) times)" : "")" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// getBills: what's due in the next days, and anything late.
    func billsText(days: Int) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: max(days, 1), to: today) ?? today
        let lateFrom = calendar.date(byAdding: .day, value: -45, to: today) ?? today
        let payments = entries.filter { $0.billID != nil }.map(\.record)
        var due: [(Bill, Date, BillState)] = []
        for bill in bills {
            for date in BudgetMath.occurrences(of: bill.record, from: lateFrom, to: end) {
                let state = BudgetMath.state(of: bill.record, dueOn: date, payments: payments)
                if date < today, state.isPaid { continue }
                due.append((bill, date, state))
            }
        }
        guard !due.isEmpty else { return "No bills are due in the next \(days) days, and none are late." }
        due.sort { $0.1 < $1.1 }
        let owed = due.filter { !$0.2.isPaid }.reduce(0) { $0 + $1.0.amountCents }
        var lines = ["Bills due in the next \(days) days (today is \(Date.now.formatted(.dateTime.weekday(.wide).month().day()))):"]
        for (bill, date, state) in due {
            let when: String = switch state {
            case .paid: "paid"
            case .overdue(let late): "\(late) day\(late == 1 ? "" : "s") late"
            case .dueToday: "due today"
            case .upcoming: "due \(date.formatted(.dateTime.weekday(.wide).month().day()))"
            }
            lines.append("\(bill.name): \(bill.amountLabel), \(when)\(bill.isAutopay ? ", autopay" : "")")
        }
        lines.append("Still to pay: \(Money.text(owed)).")
        return lines.joined(separator: "\n")
    }

    /// getSpending: where the money went in a month.
    func spendingText(monthsAgo: Int) -> String {
        let month = Self.month(monthsAgo: monthsAgo)
        let breakdown = breakdown(in: month)
        let totals = BudgetMath.totals(categories.map(\.record), entries: entries.map(\.record), in: month, stashMoves: stashMoves)
        var lines = ["\(Self.monthName(month).capitalizedFirst): \(Money.text(totals.spentCents)) spent, \(Money.text(totals.incomeCents)) came in, \(Money.text(totals.budgetedCents)) planned."]
        if totals.stashedCents > 0 { lines.append("Stashed for coming bills: \(Money.text(totals.stashedCents)).") }
        if !breakdown.rows.isEmpty {
            lines.append("By budget: " + breakdown.rows.map { "\($0.name) \(Money.text($0.cents))" }.joined(separator: ", "))
        }
        if totals.uncategorizedCents > 0 { lines.append("Not in a budget: \(Money.text(totals.uncategorizedCents)).") }
        if !breakdown.people.isEmpty {
            lines.append("By person: " + breakdown.people.map { "\($0.name) \(Money.text($0.cents))" }.joined(separator: ", "))
        }
        let over = statuses(in: month).filter { $0.limitCents > 0 && $0.isOver }.map(\.category.name)
        if !over.isEmpty { lines.append("Over budget: \(over.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    /// findTransactions: transactions whose payee, note or budget matches.
    func transactionsText(matching search: String, monthsBack: Int) -> String {
        let words = AskText.words(search)
        let from = Self.month(monthsAgo: monthsBack).start
        let lookup = Lookup(categories: categories, members: members)
        let matches = entries.filter { entry in
            guard entry.date >= from else { return false }
            let partNames = entry.record.parts.flatMap { [lookup.budget(for: $0.categoryID)?.name ?? "", lookup.category($0.categoryID)?.name ?? ""] }
            let haystack = AskText.words(([entry.payee, entry.note] + partNames).joined(separator: " "))
            return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }
        guard !matches.isEmpty else { return "No transactions match \"\(search)\" since \(from.formatted(.dateTime.month(.wide).year()))." }
        let spent = matches.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        let received = matches.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        var lines = ["\(matches.count) transaction\(matches.count == 1 ? "" : "s") match \"\(search)\" since \(from.formatted(.dateTime.month(.wide))): \(Money.text(spent)) spent\(received > 0 ? ", \(Money.text(received)) received" : "")."]
        for entry in matches.prefix(8) {
            let who = lookup.member(entry.memberID).map { ", \($0.name)" } ?? ""
            lines.append("\(entry.date.formatted(.dateTime.month(.abbreviated).day())): \(entry.payee) \(entry.kind == .income ? "+" : "")\(Money.text(entry.amountCents))\(who)")
        }
        if matches.count > 8 { lines.append("…and \(matches.count - 8) more.") }
        return lines.joined(separator: "\n")
    }

    /// checkAffordability: whether a one-off purchase fits this month.
    func affordabilityText(dollars: Int) -> String {
        let month = MonthSpan(containing: .now)
        let all = statuses(in: month)
        let overBy = all.filter { $0.limitCents > 0 }.reduce(0) { $0 + max(-$1.leftCents, 0) }
        let records = entries.map(\.record)
        let cash = BudgetMath.totalCash(accounts.map(\.record), entries: records)
        let totals = BudgetMath.totals(categories.map(\.record), entries: records, in: month, stashMoves: stashMoves)
        // This month's stash amounts are part of the plan, so they're not left to spend.
        let leftInBudgets = max(all.filter { $0.limitCents > 0 }.reduce(0) { $0 + max($1.leftCents, 0) } - totals.stashedCents, 0)
        let payments = entries.filter { $0.billID != nil }.map(\.record)
        let today = Calendar.current.startOfDay(for: .now)
        let billsLeft = bills.reduce(0) { total, bill in
            total + BudgetMath.occurrences(of: bill.record, from: today, to: month.end)
                .filter { BudgetMath.payment(for: bill.record, dueOn: $0, payments: payments) == nil }
                .count * bill.amountCents
        }
        let unplanned = totals.incomeCents - totals.budgetedCents - totals.stashedCents
        return """
        Asked about: \(Money.text(dollars * 100)).
        Left in all budgets this month: \(Money.text(leftInBudgets))\(overBy > 0 ? " (budgets already over by \(Money.text(overBy)) in total)" : "").
        Income this month minus everything planned: \(Money.text(unplanned)).
        Bills still to pay this month: \(Money.text(billsLeft)).
        Total cash in accounts: \(Money.text(cash)).
        \(Self.daysLeft) days left in the month.
        """
    }

    /// getStashes: what's stashed for the bills that come once or twice a year, and whether
    /// each is on track.
    func stashesText(named name: String = "") -> String {
        let words = AskText.words(name)
        let named = stashes.filter { stash in
            let haystack = AskText.words(stash.name)
            return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }
        let all = named.isEmpty ? stashes : named
        guard !all.isEmpty else { return "No stashes yet. A stash saves a little each month for a bill that comes once or twice a year (Budget › Stashes)." }
        let moves = stashMoves
        let paid = entries.filter { $0.stashID != nil }.map(\.record)
        var lines = ["Stashes (today is \(Date.now.formatted(.dateTime.month().day().year()))):"]
        for stash in all {
            let summary = StashMath.summary(stash.record, moves: moves, entries: paid)
            let due = stash.dueDate.formatted(.dateTime.month(.wide).day().year())
            var line = "\(stash.name): \(Money.text(summary.balanceCents)) stashed of \(Money.text(stash.targetCents)), due \(due)"
            if summary.monthlyCents > 0 { line += ", \(Money.text(summary.monthlyCents)) a month for \(summary.monthsLeft) more month\(summary.monthsLeft == 1 ? "" : "s")" }
            line += ". \(summary.status.label)."
            lines.append(line)
        }
        let month = MonthSpan(containing: .now)
        lines.append("Stashed this month: \(Money.text(StashMath.stashed(moves, in: month))).")
        return lines.joined(separator: "\n")
    }

    /// getRunway: how many months of essentials the emergency fund covers.
    /// Counted toward stashes in `month` (part of the plan, so not left to spend).
    func stashed(in month: MonthSpan) -> Int {
        StashMath.stashed(stashMoves, in: month)
    }

    func runwayText() -> String {
        let runway = EmergencyFund.runway(in: context)
        guard let months = EmergencyFund.monthsText(runway) else {
            return "Nothing is marked essential yet, so there's no runway number. Net Worth › Emergency fund picks what's essential."
        }
        var lines = [
            "Emergency fund: \(Money.text(runway.savedCents)) saved, essentials \(Money.text(runway.essentialsCents)) a month, so it would last \(months) months.",
            "Goal: \(runway.goalMonths) months.",
        ]
        if runway.gapCents > 0 {
            lines.append("Short of the goal by \(Money.text(runway.gapCents)); \(Money.text(runway.monthlyToCloseCents)) a month closes it in a year.")
        } else {
            lines.append("Past the goal by \(Money.text(runway.overCents)).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Cards

    struct Payee: Hashable {
        var name: String
        var cents: Int
        var count: Int
    }

    struct Breakdown {
        struct Row: Hashable, Identifiable {
            var id: UUID
            var name: String
            var cents: Int
            var color: CategoryColor
        }
        var month: MonthSpan
        var totalCents: Int
        var rows: [Row]
        var people: [Payee]
    }

    /// A budget's spending this month by payee, biggest first.
    func topPayees(in category: BudgetCategory, month: MonthSpan, limit: Int = 3) -> [Payee] {
        var byName: [String: Payee] = [:]
        let ids = budgetIDs(category)
        for entry in entries(in: category, from: month.start, to: month.end) {
            let key = entry.payee.lowercased()
            var payee = byName[key] ?? Payee(name: entry.payee, cents: 0, count: 0)
            // A split charge counts only its part in this budget.
            payee.cents += entry.cents(in: ids)
            payee.count += 1
            byName[key] = payee
        }
        return byName.values.sorted { $0.cents > $1.cents }.prefix(limit).map { $0 }
    }

    /// Spending in a month by budget (biggest first) and by person.
    func breakdown(in month: MonthSpan) -> Breakdown {
        let all = statuses(in: month).filter { $0.spentCents > 0 }.sorted { $0.spentCents > $1.spentCents }
        let rows = all.prefix(6).map { status in
            Breakdown.Row(id: status.id, name: status.category.name, cents: status.spentCents, color: category(status.id)?.color ?? .gray)
        }
        let spending = entries.filter { $0.kind == .expense && month.contains($0.date) }
        var people: [Payee] = []
        for member in members {
            let cents = spending.filter { $0.memberID == member.id }.reduce(0) { $0 + $1.record.spendingCents }
            if cents > 0 { people.append(Payee(name: member.name, cents: cents, count: 0)) }
        }
        return Breakdown(month: month, totalCents: spending.reduce(0) { $0 + $1.record.spendingCents }, rows: rows, people: people)
    }

    /// A budget and its subcategories.
    private func budgetIDs(_ category: BudgetCategory) -> Set<UUID> {
        Set([category.id] + categories.filter { $0.parentID == category.id }.map(\.id))
    }

    private func entries(in category: BudgetCategory, from start: Date, to end: Date) -> [LedgerEntry] {
        let ids = budgetIDs(category)
        return entries.filter { $0.kind == .expense && $0.date >= start && $0.date < end && $0.touches(ids) }
    }

    // MARK: Moving money between budgets

    struct Transfer: Hashable {
        var fromID: UUID
        var toID: UUID
        var cents: Int
    }

    /// A move the person asked for, if both budgets exist and the amount is sensible.
    func transfer(from: String, to: String, dollars: Int) -> Transfer? {
        guard dollars > 0, let source = findCategory(from), let target = findCategory(to), source.id != target.id else { return nil }
        let month = MonthSpan(containing: .now)
        let sourceLimit = status(of: source.id, in: month)?.limitCents ?? source.limitCents
        let cents = dollars * 100
        guard sourceLimit >= cents else { return nil }
        return Transfer(fromID: source.id, toID: target.id, cents: cents)
    }

    /// The monthly amounts before and after a move.
    func amounts(for transfer: Transfer) -> (from: (Int, Int), to: (Int, Int))? {
        let month = MonthSpan(containing: .now)
        guard let source = category(transfer.fromID), let target = category(transfer.toID) else { return nil }
        let fromNow = status(of: source.id, in: month)?.limitCents ?? source.limitCents
        let toNow = status(of: target.id, in: month)?.limitCents ?? target.limitCents
        return ((fromNow, fromNow - transfer.cents), (toNow, toNow + transfer.cents))
    }

    /// Moves the amount: the source's monthly amount goes down and the target's goes up.
    func apply(_ transfer: Transfer) -> Bool {
        guard let amounts = amounts(for: transfer), let source = category(transfer.fromID), let target = category(transfer.toID),
              amounts.from.1 >= 0 else { return false }
        source.limitCents = amounts.from.1
        target.limitCents = amounts.to.1
        try? context.save()
        return true
    }

    // MARK: Right now

    struct Insight: Identifiable, Hashable {
        enum Kind: Hashable {
            case budget(UUID)
            case bills(firstName: String)
            case spending
        }
        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var question: String
        var progress: Double = 0
    }

    /// For the welcome screen: budgets nearly or already spent, and bills due this week.
    func insights() -> [Insight] {
        let month = MonthSpan(containing: .now)
        var result: [Insight] = []
        let tight = statuses(in: month)
            .filter { $0.limitCents > 0 && $0.progress >= 0.8 }
            .sorted { $0.progress > $1.progress }
            .prefix(2)
        for status in tight {
            let name = status.category.name
            let detail = status.isOver
                ? "\(Money.text(-status.leftCents)) over with \(Self.daysLeft) days to go"
                : "\(Money.text(status.leftCents)) left with \(Self.daysLeft) days to go"
            result.append(Insight(
                id: "budget-\(status.id)", kind: .budget(status.id),
                title: status.isOver ? "\(name) is over budget" : "\(name) is at \(Int((status.progress * 100).rounded()))%",
                detail: detail, question: "How much is left for \(name)?", progress: status.progress
            ))
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let payments = entries.filter { $0.billID != nil }.map(\.record)
        let due = bills.flatMap { bill in
            BudgetMath.occurrences(of: bill.record, from: today, to: weekEnd)
                .filter { BudgetMath.payment(for: bill.record, dueOn: $0, payments: payments) == nil }
                .map { (bill, $0) }
        }.sorted { $0.1 < $1.1 }
        if let first = due.first {
            let total = due.reduce(0) { $0 + $1.0.amountCents }
            let when = calendar.isDateInToday(first.1) ? "today" : calendar.isDateInTomorrow(first.1) ? "tomorrow" : first.1.formatted(.dateTime.weekday(.wide))
            result.append(Insight(
                id: "bills", kind: .bills(firstName: first.0.name),
                title: due.count == 1 ? "1 bill due this week" : "\(due.count) bills due this week",
                detail: "\(Money.text(total)), \(first.0.name) \(when)",
                question: "Which bills are due this week?"
            ))
        }

        if result.isEmpty {
            let totals = BudgetMath.totals(categories.map(\.record), entries: entries.map(\.record), in: month)
            result.append(Insight(
                id: "spending", kind: .spending,
                title: "\(Money.text(totals.spentCents)) spent so far",
                detail: totals.budgetedCents > 0 ? "of \(Money.text(totals.budgetedCents)) planned for \(month.start.formatted(.dateTime.month(.wide)))" : "in \(month.start.formatted(.dateTime.month(.wide)))",
                question: "Where did our money go this month?"
            ))
        }
        return result
    }

    /// The budget most worth asking about: the one closest to its amount.
    func busiestBudgetName() -> String? {
        statuses(in: MonthSpan(containing: .now))
            .filter { $0.limitCents > 0 }
            .max { $0.progress < $1.progress }?
            .category.name
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
