import Foundation
import SwiftData

// Planning ahead: stashes for the costs that come once or twice a year. Like every model, these
// follow CloudKit's rules (every property has a default, nothing is unique, links are plain
// UUIDs), and household sync carries them (Services/Household/SyncRecords.swift).

/// Money set aside month by month for a cost that comes once or twice a year: home insurance,
/// car registration, Christmas. Its monthly amount counts in the budget like any plan, so when
/// the cost comes it's paid from the stash instead of from that month's budget. The money
/// itself stays in a real account (`accountID`); Suffice keeps the tally.
@Model
final class Stash {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "shield.fill"
    var colorRaw: String = CategoryColor.orange.rawValue
    /// What it saves toward.
    var targetCents: Int = 0
    /// When it's needed: the bill's next due date, or a date someone picked.
    var dueDate: Date = Date.now
    /// Starts over for the same date next year once it's used (home insurance), or ends
    /// (a one-time cost).
    var repeatsYearly: Bool = true
    /// What was already saved when it was made ("Already stashed").
    var openingCents: Int = 0
    /// The account the money sits in, if someone said.
    var accountID: UUID?
    /// The bill it pays: when that bill is paid, the payment comes out of this stash.
    var billID: UUID?
    /// Counts this month's amount on the 1st on its own. Off: someone marks it each month.
    var countsAutomatically: Bool = true
    /// Counts toward the emergency fund's essentials, at its yearly cost ÷ 12.
    var isEssential: Bool = false
    /// Used and done (a one-time cost), or put away by hand.
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, symbol: String = "shield.fill", color: CategoryColor = .orange, targetCents: Int, dueDate: Date, repeatsYearly: Bool = true, openingCents: Int = 0, billID: UUID? = nil, accountID: UUID? = nil, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.colorRaw = color.rawValue
        self.targetCents = targetCents
        self.dueDate = dueDate
        self.repeatsYearly = repeatsYearly
        self.openingCents = openingCents
        self.billID = billID
        self.accountID = accountID
        self.sortOrder = sortOrder
    }

    var color: CategoryColor {
        get { CategoryColor(rawValue: colorRaw) ?? .orange }
        set { colorRaw = newValue.rawValue }
    }

    var record: StashRecord {
        StashRecord(id: id, name: name, targetCents: targetCents, dueDate: dueDate, repeatsYearly: repeatsYearly, openingCents: openingCents, billID: billID, countsAutomatically: countsAutomatically, isEssential: isEssential, isArchived: isArchived, createdAt: createdAt)
    }
}

/// One month's amount counted toward a stash: added on the 1st on its own, or marked by hand.
/// Two devices can each count the same month before they sync; `SyncCleanup` folds those into
/// one.
@Model
final class StashMove {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var stashID: UUID?
    /// The first moment of the month it counts in.
    var month: Date = Date.distantPast
    var amountCents: Int = 0
    var createdAt: Date = Date.now

    init(stashID: UUID, month: Date, amountCents: Int) {
        self.stashID = stashID
        self.month = month
        self.amountCents = amountCents
    }

    var record: StashMoveRecord {
        StashMoveRecord(id: id, stashID: stashID, month: month, amountCents: amountCents)
    }
}

// MARK: - Snapshots

nonisolated struct StashRecord: Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var targetCents: Int
    var dueDate: Date
    var repeatsYearly: Bool = true
    var openingCents: Int = 0
    var billID: UUID?
    var countsAutomatically: Bool = true
    var isEssential: Bool = false
    var isArchived: Bool = false
    var createdAt: Date = .distantPast
}

nonisolated struct StashMoveRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var stashID: UUID?
    var month: Date
    var amountCents: Int
}
