import Foundation
import SwiftData

// Net worth: what the household owns (its accounts plus homes, cars and investments typed in by
// hand) minus what it owes (credit cards and loans). Like every model, these follow CloudKit's
// rules: every property has a default, nothing is unique, links are plain UUIDs. Household sync
// carries them (Services/Household/SyncRecords.swift).

/// What a loan is for. Picks its starting icon, color and name.
nonisolated enum LoanKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case mortgage, homeEquity, auto, student, personal, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mortgage: "Mortgage"
        case .homeEquity: "Home equity"
        case .auto: "Auto loan"
        case .student: "Student loan"
        case .personal: "Personal loan"
        case .other: "Other loan"
        }
    }

    var symbol: String {
        switch self {
        case .mortgage: "house.fill"
        case .homeEquity: "building.columns.fill"
        case .auto: "car.fill"
        case .student: "graduationcap.fill"
        case .personal: "banknote.fill"
        case .other: "doc.text.fill"
        }
    }

    var color: CategoryColor {
        switch self {
        case .mortgage: .orange
        case .homeEquity: .yellow
        case .auto: .blue
        case .student: .purple
        case .personal: .teal
        case .other: .gray
        }
    }

    /// A typical term, to start the editor from.
    var typicalTermMonths: Int {
        switch self {
        case .mortgage: 360
        case .homeEquity: 120
        case .auto: 60
        case .student: 120
        case .personal: 36
        case .other: 60
        }
    }
}

/// A loan paid down month by month: a mortgage, a car, student loans. Its balance on
/// `balanceDate` is what was owed then; the scheduled payments since bring it down (see
/// `LoanMath.currentBalance`), until someone types in a newer balance from a statement.
@Model
final class Loan {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var lender: String = ""
    var kindRaw: String = LoanKind.mortgage.rawValue
    var colorRaw: String = CategoryColor.orange.rawValue
    /// What was borrowed.
    var originalCents: Int = 0
    /// The yearly rate as a percent: 6.25 for 6.25%.
    var annualRate: Double = 0
    var termMonths: Int = 360
    /// The first payment's due date. Payments fall on its day of the month after that.
    var firstPaymentDate: Date = Date.now
    /// The scheduled payment, principal and interest only.
    var paymentCents: Int = 0
    /// Taxes and insurance collected with a mortgage payment. Shown, never amortized.
    var escrowCents: Int = 0
    /// Principal owed on `balanceDate`.
    var balanceCents: Int = 0
    var balanceDate: Date = Date.now
    /// The extra each month saved from Payoff Plan, for projections. Zero for none.
    var extraMonthlyCents: Int = 0
    /// The account it's paid from or synced as, if any. Unused until loans sync from a bank.
    var accountID: UUID?
    var note: String = ""
    /// Paid off: kept for the record, left out of totals.
    var isPaidOff: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, lender: String = "", kind: LoanKind, originalCents: Int, annualRate: Double, termMonths: Int, firstPaymentDate: Date, paymentCents: Int, balanceCents: Int, balanceDate: Date = .now, sortOrder: Int = 0) {
        self.name = name
        self.lender = lender
        self.kindRaw = kind.rawValue
        self.colorRaw = kind.color.rawValue
        self.originalCents = originalCents
        self.annualRate = annualRate
        self.termMonths = termMonths
        self.firstPaymentDate = firstPaymentDate
        self.paymentCents = paymentCents
        self.balanceCents = balanceCents
        self.balanceDate = balanceDate
        self.sortOrder = sortOrder
    }

    var kind: LoanKind {
        get { LoanKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var color: CategoryColor {
        get { CategoryColor(rawValue: colorRaw) ?? kind.color }
        set { colorRaw = newValue.rawValue }
    }

    var symbol: String { kind.symbol }

    var record: LoanRecord {
        LoanRecord(id: id, originalCents: originalCents, annualRate: annualRate, termMonths: termMonths, firstPaymentDate: firstPaymentDate, paymentCents: paymentCents, balanceCents: balanceCents, balanceDate: balanceDate, extraMonthlyCents: extraMonthlyCents, isPaidOff: isPaidOff)
    }
}

/// What an asset is. Picks its icon and color.
nonisolated enum AssetKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, vehicle, investment, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .home: "Home"
        case .vehicle: "Vehicle"
        case .investment: "Investment"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .vehicle: "car.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "archivebox.fill"
        }
    }

    var color: CategoryColor {
        switch self {
        case .home: .orange
        case .vehicle: .blue
        case .investment: .green
        case .other: .gray
        }
    }
}

/// Something owned that isn't a bank account: a home, a car, a 401(k). Its value is the
/// household's own estimate, updated by hand.
@Model
final class OwnedAsset {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AssetKind.home.rawValue
    var valueCents: Int = 0
    /// When the value was last set.
    var valueDate: Date = Date.now
    var note: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, kind: AssetKind, valueCents: Int, sortOrder: Int = 0) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.valueCents = valueCents
        self.sortOrder = sortOrder
    }

    var kind: AssetKind {
        get { AssetKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

/// One month's net worth, kept so the trend chart has a history. The current month's is
/// rewritten whenever the totals change; earlier months stay as they were. Two devices can
/// each write one for the same month; readers keep the latest (`NetWorthHistory.points`).
@Model
final class NetWorthSnapshot {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    /// The first moment of the month it's for.
    var month: Date = Date.distantPast
    var assetsCents: Int = 0
    var debtsCents: Int = 0
    var updatedAt: Date = Date.now
    var createdAt: Date = Date.now

    init(month: Date, assetsCents: Int, debtsCents: Int) {
        self.month = month
        self.assetsCents = assetsCents
        self.debtsCents = debtsCents
    }

    var netCents: Int { assetsCents - debtsCents }
}

// MARK: - Snapshots

/// A Sendable copy of a loan for LoanMath and tests.
nonisolated struct LoanRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var originalCents: Int
    var annualRate: Double
    var termMonths: Int
    var firstPaymentDate: Date
    var paymentCents: Int
    var balanceCents: Int
    var balanceDate: Date
    var extraMonthlyCents: Int = 0
    var isPaidOff: Bool = false
}
