import Foundation
import SwiftData

// Every model follows CloudKit's rules: every property has a default, nothing is unique, and
// there are no required relationships. Links between records are plain UUIDs (categoryID,
// memberID, accountID, billID, parentID), so deleting a category, account or person never
// deletes anyone's history; those transactions just lose that label.

/// A person in the household. Transactions remember who made them.
@Model
final class Member {
    var id: UUID = UUID()
    var name: String = ""
    var colorRaw: String = MemberColor.green.rawValue
    /// A small square JPEG (see MemberPhoto). Stored outside the database file, which CloudKit
    /// syncs as an asset.
    @Attribute(.externalStorage) var photoData: Data?
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, color: MemberColor, photoData: Data? = nil, sortOrder: Int = 0) {
        self.name = name
        self.colorRaw = color.rawValue
        self.photoData = photoData
        self.sortOrder = sortOrder
    }

    var color: MemberColor {
        get { MemberColor(rawValue: colorRaw) ?? .green }
        set { colorRaw = newValue.rawValue }
    }

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// A budget: Home, Food, Auto. Top-level budgets can hold subcategories (Mortgage and Home
/// improvements inside Home), each with its own monthly amount.
@Model
final class BudgetCategory {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "house.fill"
    var colorRaw: String = CategoryColor.orange.rawValue
    var limitCents: Int = 0
    /// The budget this is a subcategory of, or nil for a top-level budget.
    var parentID: UUID?
    /// The first month it counts in.
    var startMonth: Date = Date.distantPast
    /// Off for a one-month budget (a trip, a holiday).
    var repeatsMonthly: Bool = true
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    init(name: String, symbol: String, color: CategoryColor, limitCents: Int, parentID: UUID? = nil, startMonth: Date = .distantPast, repeatsMonthly: Bool = true, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.colorRaw = color.rawValue
        self.limitCents = limitCents
        self.parentID = parentID
        self.startMonth = startMonth
        self.repeatsMonthly = repeatsMonthly
        self.sortOrder = sortOrder
    }

    var color: CategoryColor {
        get { CategoryColor(rawValue: colorRaw) ?? .gray }
        set { colorRaw = newValue.rawValue }
    }

    var record: CategoryRecord {
        CategoryRecord(id: id, name: name, limitCents: limitCents, parentID: parentID, startMonth: startMonth, repeatsMonthly: repeatsMonthly, isArchived: isArchived, sortOrder: sortOrder)
    }
}

/// Money in or out of the household.
nonisolated enum EntryKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case expense, income

    var id: String { rawValue }
    var name: String { self == .expense ? "Expense" : "Income" }
}

/// One transaction. `amountCents` is always positive; `kind` says which way it went.
@Model
final class LedgerEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var payee: String = ""
    var amountCents: Int = 0
    var kindRaw: String = EntryKind.expense.rawValue
    /// A budget or a subcategory.
    var categoryID: UUID?
    var memberID: UUID?
    var accountID: UUID?
    var note: String = ""
    /// Set when this entry is a bill payment, so the bill shows as paid.
    var billID: UUID?
    /// Which due date of the bill this pays. Nil on payments made before bills could repeat
    /// more than monthly; those count for their month.
    var billDueDate: Date?
    /// False for transactions that arrived on their own (bank sync) until someone looks at
    /// them. Activity › New lists these and anything uncategorized.
    var isReviewed: Bool = true
    /// Where it happened, for the map on the transaction sheet.
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    /// The bank's ID for it (Plaid transaction_id), so syncing never adds it twice.
    var externalID: String?
    /// The merchant's logo for bank-synced transactions (Plaid's, or Logo.dev's by domain).
    var logoURL: String?
    var createdAt: Date = Date.now

    init(
        date: Date = .now,
        payee: String,
        amountCents: Int,
        kind: EntryKind = .expense,
        categoryID: UUID? = nil,
        memberID: UUID? = nil,
        accountID: UUID? = nil,
        note: String = "",
        billID: UUID? = nil,
        isReviewed: Bool = true
    ) {
        self.date = date
        self.payee = payee
        self.amountCents = abs(amountCents)
        self.kindRaw = kind.rawValue
        self.categoryID = categoryID
        self.memberID = memberID
        self.accountID = accountID
        self.note = note
        self.billID = billID
        self.isReviewed = isReviewed
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// Positive for income, negative for spending.
    var signedCents: Int { kind == .income ? amountCents : -amountCents }

    /// Needs a look: arrived on its own, or spending with no category yet.
    var needsReview: Bool { !isReviewed || (kind == .expense && categoryID == nil) }

    /// A plain snapshot for BudgetMath, tests and export.
    var record: EntryRecord {
        EntryRecord(id: id, date: date, payee: payee, amountCents: amountCents, kind: kind, categoryID: categoryID, memberID: memberID, accountID: accountID, billID: billID, billDueDate: billDueDate)
    }
}

/// How often a bill comes due.
nonisolated enum BillFrequency: String, CaseIterable, Identifiable, Codable, Sendable {
    /// One time only, on its start date.
    case once
    case weekly, monthly, yearly

    var id: String { rawValue }

    /// "week", "month", "year" (singular), for "Every 2 weeks".
    var unit: String {
        switch self {
        case .once: "time"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
    }
}

/// A bill or subscription that comes due on a schedule: every N weeks, months or years from
/// its first due date, or just once.
@Model
final class Bill {
    var id: UUID = UUID()
    var name: String = ""
    var amountCents: Int = 0
    /// Day of the month, 1–31, for monthly and yearly bills. In shorter months it falls on the
    /// last day.
    var dueDay: Int = 1
    var frequencyRaw: String = BillFrequency.monthly.rawValue
    /// Every how many weeks, months or years.
    var interval: Int = 1
    /// The first due date: the weekday for weekly bills, the month to count from for every-N-
    /// months bills, the month for yearly ones. distantPast on bills from before schedules.
    var startDate: Date = Date.distantPast
    /// The last date it can come due, or nil for no end.
    var endDate: Date?
    var colorRaw: String = CategoryColor.blue.rawValue
    var categoryID: UUID?
    var isAutopay: Bool = false
    /// Subscriptions are listed on their own under Bills.
    var isSubscription: Bool = false
    var isActive: Bool = true
    var note: String = ""
    var createdAt: Date = Date.now

    init(name: String, amountCents: Int, dueDay: Int, color: CategoryColor = .blue, categoryID: UUID? = nil, isAutopay: Bool = false, isSubscription: Bool = false) {
        self.name = name
        self.amountCents = amountCents
        self.dueDay = min(max(dueDay, 1), 31)
        self.colorRaw = color.rawValue
        self.categoryID = categoryID
        self.isAutopay = isAutopay
        self.isSubscription = isSubscription
    }

    var color: CategoryColor {
        get { CategoryColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    var frequency: BillFrequency {
        get { BillFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    var record: BillRecord {
        BillRecord(id: id, name: name, amountCents: amountCents, dueDay: dueDay, isAutopay: isAutopay, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
    }
}

/// What kind of account money sits in.
nonisolated enum AccountKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case checking, savings, credit, cash

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    /// Credit balances are owed, so they don't count toward Total cash.
    var isCash: Bool { self != .credit }
}

/// Where an account's numbers come from.
nonisolated enum AccountSource: String, Codable, Sendable {
    case manual, plaid, wallet

    var label: String {
        switch self {
        case .manual: "Manual"
        case .plaid: "Plaid"
        case .wallet: "Apple Wallet"
        }
    }
}

/// A bank account, card or cash. Accounts at the same institution are grouped on Overview
/// (Chase › Checking, Savings).
@Model
final class Account {
    var id: UUID = UUID()
    var institution: String = ""
    var name: String = ""
    /// Last four digits, shown as •••• 0293.
    var mask: String = ""
    var kindRaw: String = AccountKind.checking.rawValue
    var sourceRaw: String = AccountSource.manual.rawValue
    /// The balance on `balanceDate`. Manual accounts move with the transactions filed to them
    /// after that.
    var balanceCents: Int = 0
    var balanceDate: Date = Date.now
    /// Off hides it from Total cash and from the budget.
    var includeInBudget: Bool = true
    var colorHex: Int = 0x0E3E8C
    /// For bank-synced accounts: the connected bank (LinkedBank.itemID) and Plaid's account ID.
    var plaidItemID: String?
    var plaidAccountID: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(institution: String, name: String, mask: String = "", kind: AccountKind, source: AccountSource = .manual, balanceCents: Int, colorHex: Int = 0x0E3E8C, sortOrder: Int = 0) {
        self.institution = institution
        self.name = name
        self.mask = mask
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.balanceCents = balanceCents
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .checking }
        set { kindRaw = newValue.rawValue }
    }

    var source: AccountSource { AccountSource(rawValue: sourceRaw) ?? .manual }

    /// "Chase Checking"
    var displayName: String { institution.isEmpty ? name : "\(institution) \(name)" }

    var record: AccountRecord {
        AccountRecord(id: id, kind: kind, balanceCents: balanceCents, balanceDate: balanceDate, includeInBudget: includeInBudget, isManual: source == .manual)
    }
}

/// A bank connected through Plaid. The access token stays on the Lifestyle API; this keeps the
/// API's ID for it (Plaid's item_id) and where syncing left off.
@Model
final class LinkedBank {
    var id: UUID = UUID()
    var itemID: String = ""
    var institution: String = ""
    /// Plaid's /transactions/sync cursor. Empty means start from the beginning.
    var cursor: String = ""
    var lastSynced: Date?
    /// The bank wants the person to sign in again.
    var needsReconnect: Bool = false
    /// The Apple ID that connected it: only that person's sign-in can sync it.
    var connectedByAppleID: String = ""
    var createdAt: Date = Date.now

    init(itemID: String, institution: String, connectedByAppleID: String) {
        self.itemID = itemID
        self.institution = institution
        self.connectedByAppleID = connectedByAppleID
    }
}

/// "Always use this category for Chick-fil-A". New transactions from the payee get it.
@Model
final class PayeeRule {
    var id: UUID = UUID()
    /// Lowercased payee name.
    var payeeKey: String = ""
    var categoryID: UUID?
    var createdAt: Date = Date.now

    init(payee: String, categoryID: UUID?) {
        self.payeeKey = PayeeRule.key(for: payee)
        self.categoryID = categoryID
    }

    nonisolated static func key(for payee: String) -> String {
        payee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Snapshots

/// Sendable copies of the models, used by BudgetMath off the main actor and in tests.
nonisolated struct EntryRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var payee: String = ""
    var amountCents: Int
    var kind: EntryKind = .expense
    var categoryID: UUID?
    var memberID: UUID?
    var accountID: UUID?
    var billID: UUID?
    var billDueDate: Date?

    var signedCents: Int { kind == .income ? amountCents : -amountCents }
}

nonisolated struct CategoryRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var limitCents: Int
    var parentID: UUID?
    var startMonth: Date = .distantPast
    var repeatsMonthly: Bool = true
    var isArchived: Bool = false
    var sortOrder: Int = 0
}

nonisolated struct BillRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var amountCents: Int
    var dueDay: Int
    var isAutopay: Bool = false
    var frequency: BillFrequency = .monthly
    var interval: Int = 1
    var startDate: Date = .distantPast
    var endDate: Date?
}

nonisolated struct AccountRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var kind: AccountKind = .checking
    var balanceCents: Int
    var balanceDate: Date = .distantPast
    var includeInBudget: Bool = true
    var isManual: Bool = true
}
