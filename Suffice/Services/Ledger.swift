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
        context.insert(entry)
        applyRuleChoice(draft, in: context)
        save(context)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return entry
    }

    static func update(_ entry: LedgerEntry, with draft: EntryDraft, in context: ModelContext) {
        entry.date = draft.date
        entry.payee = draft.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.amountCents = abs(draft.amountCents)
        entry.kind = draft.kind
        entry.categoryID = draft.kind == .expense ? draft.categoryID : nil
        entry.memberID = draft.memberID
        entry.accountID = draft.accountID
        entry.note = draft.note
        entry.isReviewed = true
        applyRuleChoice(draft, in: context)
        save(context)
    }

    static func delete(_ entry: LedgerEntry, in context: ModelContext) {
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

    /// Saves or removes "Always use this category for <payee>" from the draft's toggle.
    private static func applyRuleChoice(_ draft: EntryDraft, in context: ModelContext) {
        guard let always = draft.alwaysUseCategory, draft.kind == .expense else { return }
        let existing = rule(for: draft.payee, in: context)
        if always, let category = draft.categoryID {
            if let existing {
                existing.categoryID = category
            } else {
                context.insert(PayeeRule(payee: draft.payee, categoryID: category))
            }
        } else if !always, let existing {
            context.delete(existing)
        }
    }

    // MARK: Bills

    /// A transaction ready to record one due date of a bill: its amount, category and date.
    /// Mark paid saves it as is; "Pay a Different Amount" opens it in the transaction sheet.
    static func paymentDraft(for bill: Bill, dueOn due: Date, memberID: UUID? = nil) -> EntryDraft {
        var draft = EntryDraft()
        draft.payee = bill.name
        draft.amountCents = bill.amountCents
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
        let entry = add(paymentDraft(for: bill, dueOn: due, memberID: memberID), in: context)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return entry
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
            if matches { context.delete(entry) }
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
        var lines = ["date,payee,amount,type,budget,subcategory,member,account,note"]
        for entry in entries {
            let amount = String(format: "%.2f", Double(entry.signedCents) / 100)
            lines.append([
                entry.date.ISO8601Format(),
                field(entry.payee),
                amount,
                entry.kind.rawValue,
                field(lookup.budget(for: entry.categoryID)?.name ?? ""),
                field(lookup.subcategory(for: entry.categoryID)?.name ?? ""),
                field(lookup.member(entry.memberID)?.name ?? ""),
                field(lookup.account(entry.accountID)?.displayName ?? ""),
                field(entry.note),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Profile › Erase Suffice data. Removes everything in the store (and, with sync on, from
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
        billID = entry.billID
        billDueDate = entry.billDueDate
    }

    var isValid: Bool { amountCents > 0 && !payee.trimmingCharacters(in: .whitespaces).isEmpty }
}
