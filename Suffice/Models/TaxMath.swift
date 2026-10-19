import Foundation

// The Tax Year screen's arithmetic and the export's rows. Pure functions, pinned by
// SufficeTests/TaxMathTests.swift. Tags are stamped on transactions when they're saved, so this
// only reads them; it never runs rules.

/// A transaction to look at for taxes, with whether a receipt is kept with it.
nonisolated struct TaxSource: Hashable, Sendable {
    var entry: EntryRecord
    var hasReceipt: Bool
    var note: String = ""
}

/// One tagged amount: a whole transaction, or one part of a split charge.
nonisolated struct TaxItem: Hashable, Sendable, Identifiable {
    var entryID: UUID
    /// Which part of a split (0 for a whole transaction).
    var partIndex: Int
    var date: Date
    var payee: String
    var cents: Int
    var tag: TaxTag
    var categoryID: UUID?
    var memberID: UUID?
    var accountID: UUID?
    var note: String
    var hasReceipt: Bool
    var isPart: Bool

    var id: String { "\(entryID.uuidString)-\(partIndex)" }
}

/// One tag's year.
nonisolated struct TaxTagTotal: Hashable, Sendable, Identifiable {
    var tag: TaxTag
    var totalCents: Int
    /// Transactions (or split parts) with this tag.
    var count: Int
    /// Of those, the ones without a receipt.
    var missingReceipts: Int

    var id: TaxTag { tag }
}

/// A year of tagged spending.
nonisolated struct TaxYearSummary: Hashable, Sendable {
    var totalCents: Int
    /// Transactions with any tagged amount (a split counts once).
    var transactions: Int
    /// Of those, the ones with a receipt.
    var withReceipt: Int
    /// Biggest first.
    var tags: [TaxTagTotal]

    var missingReceipts: Int { transactions - withReceipt }
}

nonisolated enum TaxMath {
    /// A new transaction's tag: its own when it has one, then its payee's rule, then its budget's.
    static func resolvedTag(own: TaxTag, rule: TaxTag?, budget: TaxTag?) -> TaxTag {
        if own.isTagged { return own }
        if let rule, rule.isTagged { return rule }
        if let budget, budget.isTagged { return budget }
        return .untagged
    }

    /// A budget or subcategory's tag: its own, or its budget's.
    static func budgetTag(for categoryID: UUID?, categories: [CategoryRecord]) -> TaxTag {
        guard let categoryID, let category = categories.first(where: { $0.id == categoryID }) else { return .untagged }
        if category.taxTag.isTagged { return category.taxTag }
        guard let parentID = category.parentID else { return .untagged }
        return categories.first { $0.id == parentID }?.taxTag ?? .untagged
    }

    /// The tagged amounts in `year`, newest first. A split charge's parts count by their own
    /// tags (a part without one goes by the charge's). Income isn't counted.
    static func items(_ sources: [TaxSource], year: Int, calendar: Calendar = .current) -> [TaxItem] {
        var items: [TaxItem] = []
        for source in sources {
            let entry = source.entry
            guard entry.kind == .expense, calendar.component(.year, from: entry.date) == year else { continue }
            for (index, part) in entry.parts.enumerated() {
                let tag = entry.splits.isEmpty ? entry.taxTag : (part.taxTag ?? entry.taxTag)
                guard tag.isTagged, part.amountCents > 0 else { continue }
                items.append(TaxItem(
                    entryID: entry.id,
                    partIndex: index,
                    date: entry.date,
                    payee: entry.payee,
                    cents: part.amountCents,
                    tag: tag,
                    categoryID: part.categoryID,
                    memberID: entry.memberID,
                    accountID: entry.accountID,
                    note: source.note,
                    hasReceipt: source.hasReceipt,
                    isPart: !entry.splits.isEmpty
                ))
            }
        }
        return items.sorted { ($0.date, $0.partIndex) > ($1.date, $1.partIndex) }
    }

    static func summary(_ items: [TaxItem]) -> TaxYearSummary {
        var byTag: [TaxTag: TaxTagTotal] = [:]
        for item in items {
            var line = byTag[item.tag] ?? TaxTagTotal(tag: item.tag, totalCents: 0, count: 0, missingReceipts: 0)
            line.totalCents += item.cents
            line.count += 1
            if !item.hasReceipt { line.missingReceipts += 1 }
            byTag[item.tag] = line
        }
        let transactions = Dictionary(grouping: items, by: \.entryID)
        return TaxYearSummary(
            totalCents: items.reduce(0) { $0 + $1.cents },
            transactions: transactions.count,
            withReceipt: transactions.values.filter { $0.first?.hasReceipt == true }.count,
            tags: byTag.values.sorted { ($0.totalCents, $1.tag.rawValue) > ($1.totalCents, $0.tag.rawValue) }
        )
    }

    /// The transactions with a tagged amount and no receipt, newest first, one per charge.
    static func missingReceipts(_ items: [TaxItem]) -> [TaxItem] {
        var seen: Set<UUID> = []
        return items.filter { !$0.hasReceipt && seen.insert($0.entryID).inserted }
    }

    /// "5 medical, 2 business": the tags of the transactions without receipts.
    static func missingByTag(_ items: [TaxItem]) -> [(tag: TaxTag, count: Int)] {
        let missing = items.filter { !$0.hasReceipt }
        let counts = Dictionary(grouping: missing, by: \.tag).mapValues(\.count)
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { ($0.count, $1.tag.rawValue) > ($1.count, $0.tag.rawValue) }
    }
}
