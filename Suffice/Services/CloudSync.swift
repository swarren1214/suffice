import Foundation
import OSLog
import SwiftData

/// Two devices that each started with their own data (the starter budgets, the household, the
/// same bank synced on both) end up with doubles once iCloud merges them. This folds each set
/// into one and points everything that referred to the extras at the one kept.
///
/// The one kept is always the oldest (then the lowest ID), never "the one this device made", so
/// every device picks the same one and they can't delete each other's copies.
enum SyncCleanup {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "cloud-sync")

    static func mergeDuplicates(in context: ModelContext, defaults: UserDefaults = .standard) {
        let entries = fetch(LedgerEntry.self, in: context)
        Household.mergeDuplicateMembers(in: context, entries: entries, defaults: defaults)
        mergeBudgets(in: context, entries: entries)
        mergeBanks(in: context)
        mergeAccounts(in: context, entries: entries)
        mergeRules(in: context)
        mergeBankEntries(entries, in: context)
        mergeStashMoves(in: context)
        if context.hasChanges {
            do {
                try context.save()
                log.info("Merged duplicates from iCloud")
            } catch {
                log.error("Couldn't save merged duplicates: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Each kind

    private static func mergeBudgets(in context: ModelContext, entries: [LedgerEntry]) {
        let all = fetch(BudgetCategory.self, in: context)
        guard all.count > 1 else { return }
        var replaced: [UUID: UUID] = [:]

        func merge(_ group: [BudgetCategory]) {
            guard group.count > 1 else { return }
            let keeper = oldest(group, created: \.createdAt, id: \.id)
            for extra in sortedOldestFirst(group, created: \.createdAt, id: \.id) where extra.id != keeper.id {
                if keeper.limitCents == 0 { keeper.limitCents = extra.limitCents }
                if keeper.isEssential == nil { keeper.isEssential = extra.isEssential }
                if !keeper.taxTag.isTagged { keeper.taxTagRaw = extra.taxTagRaw }
                replaced[extra.id] = keeper.id
                context.delete(extra)
            }
        }

        // Budgets first, then subcategories, which may have just moved under a kept budget.
        let parents = all.filter { $0.parentID == nil }
        for group in Dictionary(grouping: parents, by: { "\(normalized($0.name))|\($0.isArchived)" }).values {
            merge(group)
        }
        let children = all.filter { $0.parentID != nil }
        for child in children {
            if let parent = child.parentID, let kept = replaced[parent] { child.parentID = kept }
        }
        for group in Dictionary(grouping: children, by: { "\($0.parentID?.uuidString ?? "")|\(normalized($0.name))|\($0.isArchived)" }).values {
            merge(group)
        }
        guard !replaced.isEmpty else { return }

        for entry in entries {
            if let id = entry.categoryID, let kept = replaced[id] { entry.categoryID = kept }
            if entry.isSplit {
                let parts = entry.splits
                let moved = parts.map { part in
                    var part = part
                    if let id = part.categoryID, let kept = replaced[id] { part.categoryID = kept }
                    return part
                }
                if moved != parts { entry.splits = moved }
            }
        }
        for bill in fetch(Bill.self, in: context) {
            if let id = bill.categoryID, let kept = replaced[id] { bill.categoryID = kept }
        }
        for rule in fetch(PayeeRule.self, in: context) {
            if let id = rule.categoryID, let kept = replaced[id] { rule.categoryID = kept }
        }
    }

    /// The same Plaid connection twice: keep one, with the furthest sync position.
    private static func mergeBanks(in context: ModelContext) {
        let banks = fetch(LinkedBank.self, in: context).filter { !$0.itemID.isEmpty }
        for group in Dictionary(grouping: banks, by: \.itemID).values where group.count > 1 {
            let keeper = oldest(group, created: \.createdAt, id: \.id)
            for extra in sortedOldestFirst(group, created: \.createdAt, id: \.id) where extra.id != keeper.id {
                if (extra.lastSynced ?? .distantPast) > (keeper.lastSynced ?? .distantPast) {
                    keeper.cursor = extra.cursor
                    keeper.lastSynced = extra.lastSynced
                    keeper.needsReconnect = extra.needsReconnect
                }
                if keeper.institutionDomain == nil { keeper.institutionDomain = extra.institutionDomain }
                context.delete(extra)
            }
        }
    }

    /// The same bank account added by two devices.
    private static func mergeAccounts(in context: ModelContext, entries: [LedgerEntry]) {
        let accounts = fetch(Account.self, in: context).filter { $0.plaidAccountID != nil }
        var replaced: [UUID: UUID] = [:]
        for group in Dictionary(grouping: accounts, by: { $0.plaidAccountID ?? "" }).values where group.count > 1 {
            let keeper = oldest(group, created: \.createdAt, id: \.id)
            for extra in sortedOldestFirst(group, created: \.createdAt, id: \.id) where extra.id != keeper.id {
                if extra.balanceDate > keeper.balanceDate {
                    keeper.balanceCents = extra.balanceCents
                    keeper.balanceDate = extra.balanceDate
                }
                replaced[extra.id] = keeper.id
                context.delete(extra)
            }
        }
        guard !replaced.isEmpty else { return }
        for entry in entries {
            if let id = entry.accountID, let kept = replaced[id] { entry.accountID = kept }
        }
        for stash in fetch(Stash.self, in: context) {
            if let id = stash.accountID, let kept = replaced[id] { stash.accountID = kept }
        }
    }

    /// One rule per payee: the newest choice wins, keeping a category or tag only another has.
    private static func mergeRules(in context: ModelContext) {
        let rules = fetch(PayeeRule.self, in: context)
        for group in Dictionary(grouping: rules, by: \.payeeKey).values where group.count > 1 {
            let sorted = sortedOldestFirst(group, created: \.createdAt, id: \.id)
            guard let newest = sorted.last else { continue }
            for extra in sorted.reversed() where extra.id != newest.id {
                if newest.categoryID == nil { newest.categoryID = extra.categoryID }
                if !newest.taxTag.isTagged { newest.taxTagRaw = extra.taxTagRaw }
                context.delete(extra)
            }
        }
    }

    /// The same bank transaction brought in on two devices. People's own changes on either
    /// copy (category, person, note, reviewed) are kept.
    private static func mergeBankEntries(_ entries: [LedgerEntry], in context: ModelContext) {
        let fromBanks = entries.filter { $0.externalID != nil && !$0.isDeleted }
        for group in Dictionary(grouping: fromBanks, by: { $0.externalID ?? "" }).values where group.count > 1 {
            let keeper = oldest(group, created: \.createdAt, id: \.id)
            for extra in sortedOldestFirst(group, created: \.createdAt, id: \.id) where extra.id != keeper.id {
                if keeper.categoryID == nil { keeper.categoryID = extra.categoryID }
                if !keeper.isSplit && extra.isSplit { keeper.splitsJSON = extra.splitsJSON }
                if keeper.memberID == nil { keeper.memberID = extra.memberID }
                if keeper.billID == nil {
                    keeper.billID = extra.billID
                    keeper.billDueDate = extra.billDueDate
                }
                if keeper.note.isEmpty { keeper.note = extra.note }
                if keeper.stashID == nil, extra.stashID != nil {
                    keeper.stashID = extra.stashID
                    keeper.stashCents = extra.stashCents
                }
                if !keeper.taxTag.isTagged { keeper.taxTagRaw = extra.taxTagRaw }
                keeper.isReviewed = keeper.isReviewed || extra.isReviewed
                context.delete(extra)
            }
        }
    }

    /// The same month of a stash counted twice (two devices each counted the 1st before they
    /// synced): keep the oldest, so every device keeps the same one.
    private static func mergeStashMoves(in context: ModelContext) {
        let moves = fetch(StashMove.self, in: context)
        guard moves.count > 1 else { return }
        let byID = Dictionary(moves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in StashMath.duplicateGroups(moves.map(\.record)) {
            let models = group.compactMap { byID[$0.id] }
            guard models.count > 1 else { continue }
            let keeper = oldest(models, created: \.createdAt, id: \.id)
            for extra in models where extra.id != keeper.id {
                context.delete(extra)
            }
        }
    }

    // MARK: Helpers

    static func oldest<T>(_ items: [T], created: KeyPath<T, Date>, id: KeyPath<T, UUID>) -> T {
        sortedOldestFirst(items, created: created, id: id)[0]
    }

    /// Oldest first, then by ID. Dates are compared to the millisecond, which is what iCloud
    /// keeps, so the device that made a record and the devices that downloaded it agree.
    static func sortedOldestFirst<T>(_ items: [T], created: KeyPath<T, Date>, id: KeyPath<T, UUID>) -> [T] {
        func key(_ item: T) -> (Int64, String) {
            (Int64((item[keyPath: created].timeIntervalSinceReferenceDate * 1000).rounded(.down)), item[keyPath: id].uuidString)
        }
        return items.sorted { key($0) < key($1) }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fetch<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
}
