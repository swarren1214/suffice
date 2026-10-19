import Foundation
import OSLog
import SwiftData

/// Keeps stashes current: counts each automatic stash's amount on the 1st, starts a yearly
/// stash over once its date has passed, and pays bills from their stashes. Runs on launch, when
/// the app comes to the foreground, and after household sync brings changes in. Two devices can
/// both count the same 1st before they sync; `SyncCleanup` folds those into one.
@MainActor
enum StashScheduler {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "stashes")

    /// Counts every 1st owed by automatic stashes and rolls yearly ones without a bill over to
    /// next year once their date has passed. Saves when anything changed.
    static func run(in context: ModelContext, today: Date = .now, calendar: Calendar = .current) {
        let stashes = ((try? context.fetch(FetchDescriptor<Stash>())) ?? []).filter { !$0.isArchived }
        guard !stashes.isEmpty else { return }
        let moves = (try? context.fetch(FetchDescriptor<StashMove>())) ?? []
        let paid = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.stashID != nil }))) ?? []).map(\.record)
        var changed = false

        for stash in stashes {
            var own = moves.filter { $0.stashID == stash.id }.map(\.record)

            /// Counts the 1sts owed up to `through` (or the due month, if sooner).
            func count(through: Date) {
                guard stash.countsAutomatically else { return }
                let record = stash.record
                var balance = StashMath.balance(of: record, moves: own, entries: paid)
                for month in StashMath.monthsToCount(record, lastCounted: own.map(\.month).max(), today: through, calendar: calendar) {
                    let amount = StashMath.amount(for: record, month: month, balanceBefore: balance, calendar: calendar)
                    guard amount > 0 else { continue }
                    let move = StashMove(stashID: stash.id, month: month, amountCents: amount)
                    context.insert(move)
                    own.append(move.record)
                    balance += amount
                    changed = true
                }
            }

            // This cycle's 1sts first, so a stash opened again after months away finishes
            // this year's target before it starts over.
            count(through: today)
            // A stash without a bill (Christmas) starts over on its own the day after its date.
            // One with a bill starts over when the bill is paid from it (`payBill`).
            if stash.repeatsYearly, stash.billID == nil {
                var rolled = false
                var guardCount = 0
                while calendar.startOfDay(for: today) > calendar.startOfDay(for: stash.dueDate), guardCount < 50 {
                    stash.dueDate = calendar.date(byAdding: .year, value: 1, to: stash.dueDate) ?? today
                    guardCount += 1
                    rolled = true
                    changed = true
                }
                if rolled { count(through: today) }
            }
        }
        if changed {
            do {
                try context.save()
            } catch {
                log.error("Couldn't save stash amounts: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// "Mark Stashed": counts this month's amount for a stash someone marks by hand.
    static func markStashed(_ stash: Stash, in context: ModelContext, today: Date = .now, calendar: Calendar = .current) {
        let month = MonthSpan(containing: today, calendar: calendar)
        let moves = self.moves(of: stash, in: context).map(\.record)
        guard !moves.contains(where: { month.contains($0.month) }) else { return }
        let saved = balance(of: stash, in: context)
        let amount = StashMath.amount(for: stash.record, month: month.start, balanceBefore: saved, calendar: calendar)
        guard amount > 0 else { return }
        context.insert(StashMove(stashID: stash.id, month: month.start, amountCents: amount))
        try? context.save()
    }

    /// Takes back this month's amount (a mark made by mistake).
    static func unmarkStashed(_ stash: Stash, in context: ModelContext, today: Date = .now, calendar: Calendar = .current) {
        let month = MonthSpan(containing: today, calendar: calendar)
        for move in moves(of: stash, in: context) where month.contains(move.month) {
            context.delete(move)
        }
        try? context.save()
    }

    // MARK: Paying from a stash

    static func moves(of stash: Stash, in context: ModelContext) -> [StashMove] {
        let id: UUID? = stash.id
        return (try? context.fetch(FetchDescriptor<StashMove>(predicate: #Predicate { $0.stashID == id }))) ?? []
    }

    /// The transactions a stash paid for.
    static func payments(from stash: Stash, in context: ModelContext) -> [LedgerEntry] {
        let id: UUID? = stash.id
        return (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.stashID == id }))) ?? []
    }

    /// What a stash has now, not counting what `excluding` already drew from it.
    static func balance(of stash: Stash, excluding entryID: UUID? = nil, in context: ModelContext) -> Int {
        let paid = payments(from: stash, in: context).filter { $0.id != entryID }.map(\.record)
        return StashMath.balance(of: stash.record, moves: moves(of: stash, in: context).map(\.record), entries: paid)
    }

    static func stash(_ id: UUID?, in context: ModelContext) -> Stash? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Stash>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Spending paid from a stash (picked on the transaction sheet): the stash covers what it
    /// can. Nil clears it. Doesn't save.
    static func pay(_ entry: LedgerEntry, from stash: Stash?, in context: ModelContext) {
        guard let stash, entry.kind == .expense else {
            entry.stashID = nil
            entry.stashCents = 0
            return
        }
        let available = balance(of: stash, excluding: entry.id, in: context)
        entry.stashID = stash.id
        entry.stashCents = StashMath.covered(paymentCents: entry.amountCents, balanceCents: available)
    }

    /// A bill payment just recorded (Mark Paid, or matched from the bank): when the bill has a
    /// stash, the payment comes out of it. Then a yearly stash starts over for next year and a
    /// one-time one is done. Doesn't save.
    static func payBill(_ entry: LedgerEntry, in context: ModelContext, calendar: Calendar = .current) {
        guard let billID = entry.billID, entry.stashID == nil, entry.kind == .expense else { return }
        let stashes = ((try? context.fetch(FetchDescriptor<Stash>())) ?? []).filter { !$0.isArchived && $0.billID == billID }
        guard let stash = stashes.min(by: { $0.dueDate < $1.dueDate }) else { return }
        // Only a payment around its date counts: not one for an earlier due date months before.
        let window = calendar.date(byAdding: .month, value: -2, to: stash.dueDate) ?? stash.dueDate
        guard (entry.billDueDate ?? entry.date) >= window else { return }

        pay(entry, from: stash, in: context)
        rollOver(stash, calendar: calendar)
        log.info("Paid a bill from its stash")
    }

    /// Once its bill is paid: a yearly stash starts over for the same date next year, and a
    /// one-time one is done.
    static func rollOver(_ stash: Stash, calendar: Calendar = .current) {
        if stash.repeatsYearly {
            stash.dueDate = StashMath.nextCycle(after: stash.dueDate, targetCents: stash.targetCents, calendar: calendar).dueDate
        } else {
            stash.isArchived = true
        }
    }

    /// A bill payment paid from its stash is going away (Mark Paid undone, or deleted): the
    /// stash goes back to the cycle it paid, so paying again draws from it again. Doesn't save.
    static func unpayBill(_ entry: LedgerEntry, in context: ModelContext, calendar: Calendar = .current) {
        guard let billID = entry.billID, let stash = stash(entry.stashID, in: context), stash.billID == billID else { return }
        let paidFor = entry.billDueDate ?? entry.date
        if stash.repeatsYearly {
            // Rolled forward when it was paid: about a year past the date it paid.
            if stash.dueDate > paidFor.addingTimeInterval(180 * 86_400) {
                stash.dueDate = calendar.date(byAdding: .year, value: -1, to: stash.dueDate) ?? stash.dueDate
            }
        } else {
            stash.isArchived = false
        }
    }

    /// The amount of a stash-paid transaction changed: less keeps what was covered (up to the
    /// new amount), more takes what the stash has. Doesn't save.
    static func amountChanged(_ entry: LedgerEntry, from oldCents: Int, in context: ModelContext) {
        guard entry.stashID != nil, entry.amountCents != oldCents else { return }
        if entry.kind != .expense {
            pay(entry, from: nil, in: context)
        } else if entry.amountCents < oldCents {
            entry.stashCents = min(entry.stashCents, entry.amountCents)
        } else {
            pay(entry, from: stash(entry.stashID, in: context), in: context)
        }
    }
}
