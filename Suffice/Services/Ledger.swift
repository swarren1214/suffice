import Foundation
import SwiftData
import UIKit

/// Adds, changes and removes transactions, bill payments and payee rules. Views call these
/// instead of inserting into the model context themselves, so saving and haptics happen in one
/// place.
enum Ledger {
    @discardableResult
    static func add(_ draft: EntryDraft, in context: ModelContext) -> LedgerEntry {
        let entry = LedgerEntry(
            date: draft.date,
            payee: draft.payee.trimmingCharacters(in: .whitespacesAndNewlines),
            amountCents: draft.amountCents,
            kind: draft.kind,
            categoryID: draft.kind == .expense ? draft.categoryID : nil,
            memberID: draft.memberID,
            accountID: draft.accountID,
            note: draft.note,
            billID: draft.billID
        )
        entry.billDueDate = draft.billDueDate
        entry.receiptData = draft.receipt
        applySplits(draft, to: entry)
        context.insert(entry)
        applyRuleChoice(draft, in: context)
        applyTaxRuleChoice(draft, in: context)
        entry.taxTag = draft.taxTagChosen ? draft.taxTag : stampedTag(own: .untagged, payee: entry.payee, categoryID: entry.categoryID, kind: entry.kind, in: context)
        if draft.stashID != nil {
            let stash = StashScheduler.stash(draft.stashID, in: context)
            StashScheduler.pay(entry, from: stash, in: context)
            // Paying a bill from its own stash (Pay a Different Amount) starts it over.
            if let stash, let billID = entry.billID, stash.billID == billID {
                StashScheduler.rollOver(stash)
            }
        } else {
            StashScheduler.payBill(entry, in: context)
        }
        save(context)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return entry
    }

    static func update(_ entry: LedgerEntry, with draft: EntryDraft, in context: ModelContext) {
        let oldStashID = entry.stashID
        let oldAmount = entry.amountCents
        let oldKind = entry.kind
        entry.date = draft.date
        entry.payee = draft.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.amountCents = abs(draft.amountCents)
        entry.kind = draft.kind
        entry.categoryID = draft.kind == .expense ? draft.categoryID : nil
        entry.memberID = draft.memberID
        entry.accountID = draft.accountID
        entry.note = draft.note
        if entry.receiptData != draft.receipt {
            // A receipt from email that's removed or replaced is no longer from email.
            if !entry.receiptSourceRaw.isEmpty {
                ReceiptScanner.shared.detach(from: entry, in: context)
            }
            entry.receiptData = draft.receipt
        }
        applySplits(draft, to: entry)
        entry.isReviewed = true
        applyRuleChoice(draft, in: context)
        applyTaxRuleChoice(draft, in: context)
        if draft.taxTagChosen {
            entry.taxTag = draft.taxTag
        } else if !entry.taxTag.isTagged {
            entry.taxTag = stampedTag(own: .untagged, payee: entry.payee, categoryID: entry.categoryID, kind: entry.kind, in: context)
        }
        // A different stash (or none) covers it afresh; a new amount adjusts what's covered.
        // Otherwise coverage stays as it was when it was paid.
        if draft.stashID != oldStashID || draft.kind != oldKind {
            StashScheduler.pay(entry, from: StashScheduler.stash(draft.stashID, in: context), in: context)
        } else {
            StashScheduler.amountChanged(entry, from: oldAmount, in: context)
        }
        save(context)
    }

    /// A split's parts, when they still add up to the amount (the amount may have been changed
    /// after splitting; then the last part takes the difference). Spending only.
    private static func applySplits(_ draft: EntryDraft, to entry: LedgerEntry) {
        guard draft.kind == .expense, draft.splits.count > 1 else {
            entry.splits = []
            return
        }
        let parts = SplitMath.remaining(total: entry.amountCents, parts: draft.splits) == 0
            ? SplitMath.cleaned(draft.splits)
            : SplitMath.rebalanced(draft.splits, total: entry.amountCents)
        entry.splits = parts
        if let primary = SplitMath.primaryCategory(parts) { entry.categoryID = primary }
    }

    /// Split parts filed to a subcategory that's going away move to `newID` (its budget).
    static func moveSplitParts(from oldID: UUID, to newID: UUID?, in context: ModelContext) {
        let split = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.splitsJSON != "" }))) ?? []
        for entry in split {
            let parts = entry.splits
            guard parts.contains(where: { $0.categoryID == oldID }) else { continue }
            entry.splits = parts.map { part in
                var part = part
                if part.categoryID == oldID { part.categoryID = newID }
                return part
            }
        }
    }

    static func delete(_ entry: LedgerEntry, in context: ModelContext) {
        StashScheduler.unpayBill(entry, in: context)
        // A receipt from email goes back to waiting for its transaction.
        if !entry.receiptSourceRaw.isEmpty {
            let id: UUID? = entry.id
            for found in (try? context.fetch(FetchDescriptor<FoundReceipt>(predicate: #Predicate { $0.entryID == id }))) ?? [] {
                found.entryID = nil
                found.status = .waiting
            }
        }
        context.delete(entry)
        save(context)
    }

    // MARK: Payee rules

    /// The category a payee is always filed under, if someone said so.
    static func ruleCategory(for payee: String, in context: ModelContext) -> UUID? {
        rule(for: payee, in: context)?.categoryID
    }

    static func rule(for payee: String, in context: ModelContext) -> PayeeRule? {
        let key = PayeeRule.key(for: payee)
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<PayeeRule>(predicate: #Predicate { $0.payeeKey == key })
        return try? context.fetch(descriptor).first
    }

    /// Saves or removes "Always use this category for <payee>" from the draft's toggle. A rule
    /// that also tags keeps its tag.
    private static func applyRuleChoice(_ draft: EntryDraft, in context: ModelContext) {
        // A split charge has no one category to always use.
        guard let always = draft.alwaysUseCategory, draft.kind == .expense, draft.splits.isEmpty else { return }
        let existing = rule(for: draft.payee, in: context)
        if always, let category = draft.categoryID {
            if let existing {
                existing.categoryID = category
            } else {
                context.insert(PayeeRule(payee: draft.payee, categoryID: category))
            }
        } else if !always, let existing {
            existing.categoryID = nil
            if existing.isEmpty { context.delete(existing) }
        }
    }

    // MARK: Tax tags

    /// The tag a transaction gets when it has none of its own: its payee's rule, then its
    /// budget's (or its subcategory's budget's). Spending only.
    static func stampedTag(own: TaxTag, payee: String, categoryID: UUID?, kind: EntryKind, in context: ModelContext) -> TaxTag {
        guard kind == .expense else { return own }
        let categories = ((try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []).map(\.record)
        return TaxMath.resolvedTag(
            own: own,
            rule: rule(for: payee, in: context)?.taxTag,
            budget: TaxMath.budgetTag(for: categoryID, categories: categories)
        )
    }

    /// Stamps a tag on a transaction that has none (one that just arrived from the bank).
    static func stampTaxTag(_ entry: LedgerEntry, in context: ModelContext) {
        guard !entry.taxTag.isTagged else { return }
        entry.taxTag = stampedTag(own: .untagged, payee: entry.payee, categoryID: entry.categoryID, kind: entry.kind, in: context)
    }

    /// Saves or removes "Always tag <payee> as <tag>" from the draft's switch, and tags this
    /// year's earlier transactions from the payee when asked to.
    private static func applyTaxRuleChoice(_ draft: EntryDraft, in context: ModelContext) {
        guard let always = draft.alwaysTagPayee, draft.kind == .expense,
              !draft.payee.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let existing = rule(for: draft.payee, in: context)
        if always, draft.taxTag.isTagged {
            if let existing {
                existing.taxTag = draft.taxTag
            } else {
                context.insert(PayeeRule(payee: draft.payee, categoryID: nil, taxTag: draft.taxTag))
            }
            if draft.tagsEarlier {
                for entry in untaggedThisYear(payee: draft.payee, in: context) { entry.taxTag = draft.taxTag }
            }
        } else if !always, let existing {
            existing.taxTag = .untagged
            if existing.isEmpty { context.delete(existing) }
        }
    }

    /// This year's spending from `payee` with no tag yet.
    static func untaggedThisYear(payee: String, in context: ModelContext, calendar: Calendar = .current) -> [LedgerEntry] {
        let key = PayeeRule.key(for: payee)
        return untaggedThisYear(in: context, calendar: calendar) { PayeeRule.key(for: $0.payee) == key }
    }

    /// This year's spending filed under any of `categoryIDs` with no tag yet.
    static func untaggedThisYear(in categoryIDs: Set<UUID>, context: ModelContext, calendar: Calendar = .current) -> [LedgerEntry] {
        untaggedThisYear(in: context, calendar: calendar) { $0.touches(categoryIDs) }
    }

    private static func untaggedThisYear(in context: ModelContext, calendar: Calendar, where matches: (LedgerEntry) -> Bool) -> [LedgerEntry] {
        guard let start = calendar.dateInterval(of: .year, for: .now)?.start else { return [] }
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start && $0.taxTagRaw == "" })
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.kind == .expense && matches($0) }
    }

    // MARK: Bills

    /// A transaction ready to record one due date of a bill: its amount, category and date.
    /// Mark paid saves it as is; "Pay a Different Amount" opens it in the transaction sheet.
    /// `amountCents` is what's due when it's known (from the bill's statement); else the bill's
    /// amount.
    static func paymentDraft(for bill: Bill, dueOn due: Date, memberID: UUID? = nil, amountCents: Int? = nil) -> EntryDraft {
        var draft = EntryDraft()
        draft.payee = bill.name
        draft.amountCents = amountCents ?? bill.amountCents
        draft.categoryID = bill.categoryID
        draft.memberID = memberID
        // Paid today, or on the due date when catching up on one more than a month old.
        let calendar = Calendar.current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: .now) ?? .now
        draft.date = due < monthAgo ? due : .now
        draft.billID = bill.id
        draft.billDueDate = calendar.startOfDay(for: due)
        return draft
    }

    /// Records one due date of a bill as paid.
    @discardableResult
    static func pay(_ bill: Bill, dueOn due: Date, memberID: UUID? = nil, in context: ModelContext) -> LedgerEntry {
        // A statement for this due date says what was actually due.
        let amount = BillStatements.amount(for: bill, dueOn: due, in: context)
        let entry = add(paymentDraft(for: bill, dueOn: due, memberID: memberID, amountCents: amount), in: context)
        // Its statement goes with the payment, as its receipt.
        if entry.receiptData == nil, let statement = statementDocument(for: bill, dueOn: due, in: context) {
            entry.receiptData = statement
            save(context)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return entry
    }

    /// The statement for a due date as a JPEG, when it was kept, to attach to its payment.
    private static func statementDocument(for bill: Bill, dueOn due: Date, in context: ModelContext) -> Data? {
        guard let match = StatementMath.statement(for: bill.record, dueOn: due, statements: BillStatements.records(in: context)) else { return nil }
        let id = match.id
        var descriptor = FetchDescriptor<BillStatement>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let statement = try? context.fetch(descriptor).first, let data = statement.documentData else { return nil }
        return statement.documentType == "pdf" ? DocumentImage.jpeg(fromPDF: data) : data
    }

    /// Undoes Mark paid for one due date: removes the payments recorded for it.
    static func unpay(_ bill: Bill, dueOn due: Date, context: ModelContext) {
        let id = bill.id
        let descriptor = FetchDescriptor<LedgerEntry>()
        let payments = ((try? context.fetch(descriptor)) ?? []).filter { $0.billID == id }
        let calendar = Calendar.current
        for entry in payments {
            let matches = entry.billDueDate.map { calendar.isDate($0, inSameDayAs: due) }
                ?? calendar.isDate(entry.date, equalTo: due, toGranularity: .month)
            if matches {
                StashScheduler.unpayBill(entry, in: context)
                context.delete(entry)
            }
        }
        save(context)
    }

    // MARK: Data

    /// Every transaction as CSV, for Profile › About › Export.
    static func csv(in context: ModelContext) -> String {
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let lookup = Lookup(
            categories: (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? [],
            members: (try? context.fetch(FetchDescriptor<Member>())) ?? [],
            accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? []
        )
        func field(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["date,payee,amount,type,budget,subcategory,member,account,note,tax tag"]
        for entry in entries {
            // A split charge is a line per part, each with its budget, so the budgets add up in a
            // spreadsheet; the note says which charge they came from.
            let parts = entry.kind == .expense ? entry.record.parts : [EntrySplit(categoryID: entry.categoryID, amountCents: entry.amountCents)]
            for part in parts {
                let cents = entry.kind == .income ? part.amountCents : -part.amountCents
                let note = entry.isSplit ? [entry.note, "Part of a \(Money.text(entry.amountCents)) split"].filter { !$0.isEmpty }.joined(separator: " · ") : entry.note
                lines.append([
                    entry.date.ISO8601Format(),
                    field(entry.payee),
                    String(format: "%.2f", Double(cents) / 100),
                    entry.kind.rawValue,
                    field(lookup.budget(for: part.categoryID)?.name ?? ""),
                    field(lookup.subcategory(for: part.categoryID)?.name ?? ""),
                    field(lookup.member(entry.memberID)?.name ?? ""),
                    field(lookup.account(entry.accountID)?.displayName ?? ""),
                    field(note),
                    field((entry.isSplit ? part.taxTag ?? entry.taxTag : entry.taxTag).exportName),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Profile › Erase App Data. Removes everything in the store (and, with sync on, from
    /// iCloud), then puts the starter budgets back.
    static func eraseEverything(in context: ModelContext) {
        // One by one rather than in bulk, so open screens see each deletion.
        func deleteAll<T: PersistentModel>(_ type: T.Type) {
            for model in (try? context.fetch(FetchDescriptor<T>())) ?? [] {
                context.delete(model)
            }
        }
        deleteAll(LedgerEntry.self)
        deleteAll(Bill.self)
        deleteAll(Account.self)
        deleteAll(PayeeRule.self)
        deleteAll(LinkedBank.self)
        deleteAll(Loan.self)
        deleteAll(OwnedAsset.self)
        deleteAll(NetWorthSnapshot.self)
        deleteAll(StashMove.self)
        deleteAll(Stash.self)
        deleteAll(BillStatement.self)
        deleteAll(FoundReceipt.self)
        deleteAll(BudgetCategory.self)
        deleteAll(Member.self)
        StarterData.insertBudgets(into: context)
        save(context)
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// The editable fields of a transaction, before it's saved.
struct EntryDraft: Equatable {
    var payee: String = ""
    var amountCents: Int = 0
    var kind: EntryKind = .expense
    var categoryID: UUID?
    var memberID: UUID?
    var accountID: UUID?
    var date: Date = .now
    var note: String = ""
    var billID: UUID?
    var billDueDate: Date?
    /// The "Always use this category" switch: nil leaves any rule alone.
    var alwaysUseCategory: Bool?
    /// The receipt photo (JPEG).
    var receipt: Data?
    /// The parts of a split charge; empty when it isn't split.
    var splits: [EntrySplit] = []
    /// The stash it's paid from, if any.
    var stashID: UUID?
    var taxTag: TaxTag = .untagged
    /// Someone picked the tag on the sheet. Otherwise saving stamps one from the payee's rule
    /// or the budget when it has none.
    var taxTagChosen = false
    /// The "Always tag <payee>" switch: nil leaves any rule alone.
    var alwaysTagPayee: Bool?
    /// Also tag this year's earlier transactions from the payee (asked when the switch goes on).
    var tagsEarlier = false

    init() {}

    init(_ entry: LedgerEntry) {
        payee = entry.payee
        amountCents = entry.amountCents
        kind = entry.kind
        categoryID = entry.categoryID
        memberID = entry.memberID
        accountID = entry.accountID
        date = entry.date
        note = entry.note
        receipt = entry.receiptData
        billID = entry.billID
        billDueDate = entry.billDueDate
        splits = entry.splits
        stashID = entry.stashID
        taxTag = entry.taxTag
    }

    var isSplit: Bool { splits.count > 1 }

    var isValid: Bool { amountCents > 0 && !payee.trimmingCharacters(in: .whitespaces).isEmpty }
}
