import Foundation
import SwiftData

/// Marks bills paid on their own: a bank transaction from the bill's payee, for about the
/// bill's amount, near a due date that isn't paid yet, becomes that due date's payment (and
/// lands in the bill's budget if it has none).
@MainActor
enum BillMatcher {
    /// How far from a due date a payment can land and still count for it.
    static let window: TimeInterval = 10 * 86_400

    /// Links whichever of `entries` pay a bill. Doesn't save.
    static func link(_ entries: [LedgerEntry], in context: ModelContext, calendar: Calendar = .current) {
        let candidates = entries.filter { $0.kind == .expense && $0.billID == nil }
        guard !candidates.isEmpty else { return }
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter(\.isActive)
        guard !bills.isEmpty else { return }
        var payments = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.billID != nil }))) ?? []).map(\.record)

        for entry in candidates.sorted(by: { $0.date < $1.date }) {
            guard let (bill, due) = match(entry.record, bills: bills, payments: payments, calendar: calendar) else { continue }
            entry.billID = bill.id
            entry.billDueDate = due
            if entry.categoryID == nil { entry.categoryID = bill.categoryID }
            payments.append(entry.record)
        }
    }

    /// The bill and due date a payment is for, if it's for one.
    static func match(_ entry: EntryRecord, bills: [Bill], payments: [EntryRecord], calendar: Calendar = .current) -> (Bill, Date)? {
        let payee = PayeeKey.normalized(entry.payee)
        guard !payee.isEmpty else { return nil }
        for bill in bills where PayeeKey.matches(payee, PayeeKey.normalized(bill.name)) && fits(entry.amountCents, bill) {
            let record = bill.record
            let dues = BudgetMath.occurrences(
                of: record,
                from: entry.date.addingTimeInterval(-window),
                to: entry.date.addingTimeInterval(window),
                calendar: calendar
            )
            let open = dues.filter { BudgetMath.payment(for: record, dueOn: $0, payments: payments, calendar: calendar) == nil }
            if let due = open.min(by: { abs($0.timeIntervalSince(entry.date)) < abs($1.timeIntervalSince(entry.date)) }) {
                return (bill, due)
            }
        }
        return nil
    }

    /// About the bill's amount: within 10% (at least $2) for a steady bill, inside its range
    /// (or half to double its average) for a variable one.
    static func fits(_ cents: Int, _ bill: Bill) -> Bool {
        guard bill.amountCents > 0 else { return false }
        if bill.isVariable {
            let low = bill.minCents.map { $0 * 8 / 10 } ?? bill.amountCents / 2
            let high = bill.maxCents.map { $0 * 12 / 10 } ?? bill.amountCents * 2
            return (low...max(low, high)).contains(cents)
        }
        return abs(cents - bill.amountCents) <= max(200, bill.amountCents / 10)
    }
}

/// Onboarding's suggestions, put into the budget.
@MainActor
enum PlanSetup {
    /// Adds the bills that were kept, each with its schedule and budget, and links the
    /// payments already made to them so this month's shows as paid. Saves.
    static func track(_ found: [SpendingHistory.FoundBill], in context: ModelContext, calendar: Calendar = .current) {
        guard !found.isEmpty else { return }
        let categories = ((try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []).filter { !$0.isArchived }
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID != nil }))) ?? []
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for item in found {
            let category = item.budgetName.flatMap { name in
                categories.first { $0.parentID == nil && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }
            let bill = Bill(
                name: item.name,
                amountCents: item.amountCents,
                dueDay: item.dueDay,
                color: category?.color ?? .blue,
                categoryID: category?.id,
                isSubscription: item.isSubscription
            )
            bill.isVariable = item.isVariable
            bill.minCents = item.minCents
            bill.maxCents = item.maxCents
            bill.startDate = MonthSpan(containing: item.firstDate, calendar: calendar).dueDate(day: item.dueDay, calendar: calendar)
            context.insert(bill)
        }
        try? context.save()
        BillMatcher.link(found.flatMap(\.entryIDs).compactMap { byID[$0] }, in: context, calendar: calendar)
        try? context.save()
    }
}
