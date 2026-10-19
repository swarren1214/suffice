import Foundation
import SwiftData

// Bills and receipts read from documents: a bill's statements (from email, a shared PDF or a
// scanned paper bill) and the receipts found in a connected mailbox. Statements follow the
// CloudKit rules like every synced model; found receipts stay on the device that read the
// mailbox (only the receipt image they attach to a transaction syncs, on the transaction).

/// Where a bill statement came from.
nonisolated enum StatementSource: String, Codable, Sendable {
    case email, shared, scanned

    var label: String {
        switch self {
        case .email: "from your email"
        case .shared: "shared to Suffice"
        case .scanned: "scanned"
        }
    }
}

/// One charge on a bill: "Water $58.10".
nonisolated struct StatementCharge: Hashable, Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var amountCents: Int
}

/// One bill as it arrived: what's due, by when, for which period, and its charges. A variable
/// bill's amount for a due date comes from its statement (`StatementMath.amount`).
@Model
final class BillStatement {
    /// Kept in history after deletion, so household sync can tell iCloud which record went.
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    /// The bill it's for; nil until someone picks one.
    var billID: UUID?
    var amountCents: Int = 0
    var dueDate: Date = Date.now
    var periodStart: Date?
    var periodEnd: Date?
    /// The charges as JSON (see `charges`).
    var chargesJSON: String = ""
    var sourceRaw: String = StatementSource.shared.rawValue
    /// Who sent it ("Santaquin City") and the file's name, for the review card.
    var sender: String = ""
    var fileName: String = ""
    /// The bill itself, a PDF or a JPEG. Stored outside the database; household sync carries it
    /// as an asset.
    @Attribute(.externalStorage) var documentData: Data?
    /// "pdf" or "jpeg".
    var documentType: String = "pdf"
    /// Someone looked it over. New ones show on Bills until they do.
    var isReviewed: Bool = false
    /// Its amount counts for its due date (off keeps the bill's usual amount).
    var usesAmount: Bool = true
    /// The mailbox's ID for the email it came in, so it's never read twice.
    var emailID: String = ""
    var createdAt: Date = Date.now

    init(billID: UUID?, amountCents: Int, dueDate: Date, source: StatementSource) {
        self.billID = billID
        self.amountCents = amountCents
        self.dueDate = dueDate
        self.sourceRaw = source.rawValue
    }

    var source: StatementSource { StatementSource(rawValue: sourceRaw) ?? .shared }

    var charges: [StatementCharge] {
        get {
            guard !chargesJSON.isEmpty, let data = chargesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([StatementCharge].self, from: data)) ?? []
        }
        set {
            guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else {
                chargesJSON = ""
                return
            }
            chargesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    var record: StatementRecord {
        StatementRecord(id: id, billID: billID, amountCents: amountCents, dueDate: dueDate, usesAmount: usesAmount, isReviewed: isReviewed)
    }
}

/// Where a receipt found in email stands.
nonisolated enum FoundReceiptStatus: String, Codable, Sendable {
    /// Attached to its transaction.
    case attached
    /// A close match waiting for someone to say yes or no.
    case check
    /// No transaction yet (the bank hasn't sent it); matched again on later scans.
    case waiting
    /// Someone said Not This One, or it waited too long.
    case dismissed
}

/// A receipt found in a connected mailbox, and what became of it. On this device only.
@Model
final class FoundReceipt {
    var id: UUID = UUID()
    /// "gmail" or "outlook", and the mailbox's ID for the message.
    var provider: String = ""
    var messageID: String = ""
    /// Opens the message in the mailbox on the web.
    var webLink: String = ""
    var subject: String = ""
    var sender: String = ""
    var receivedAt: Date = Date.now
    var merchant: String = ""
    var totalCents: Int = 0
    /// When it was paid, from the receipt (or when it arrived).
    var paidOn: Date = Date.now
    var statusRaw: String = FoundReceiptStatus.waiting.rawValue
    /// The transaction it's attached to, or the one it might be.
    var entryID: UUID?
    /// Why it needs a look ("Off by $16.82, about a 20% tip").
    var reason: String = ""
    /// The receipt as an image, ready to attach.
    @Attribute(.externalStorage) var imageData: Data?
    var createdAt: Date = Date.now

    init(provider: String, messageID: String) {
        self.provider = provider
        self.messageID = messageID
    }

    var status: FoundReceiptStatus {
        get { FoundReceiptStatus(rawValue: statusRaw) ?? .waiting }
        set { statusRaw = newValue.rawValue }
    }

    var candidate: ReceiptCandidate {
        ReceiptCandidate(merchant: merchant, totalCents: totalCents, date: paidOn)
    }
}

// MARK: - Snapshots

nonisolated struct StatementRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var billID: UUID?
    var amountCents: Int
    var dueDate: Date
    var usesAmount: Bool = true
    var isReviewed: Bool = true
}

// MARK: - Statements

nonisolated enum StatementMath {
    /// How far a statement's due date can be from the schedule's and still be that due date's
    /// bill (a weekend, or a city that shifts it a day or two).
    static let window: TimeInterval = 10 * 86_400

    /// The statement for one due date of a bill: the closest within the window that counts.
    static func statement(for bill: BillRecord, dueOn due: Date, statements: [StatementRecord]) -> StatementRecord? {
        // A weekly bill's due dates are close together: half the gap, so one statement is
        // never two due dates' bill.
        let reach = bill.frequency == .weekly ? min(window, Double(max(bill.interval, 1)) * 7 * 86_400 / 2) : window
        return statements
            .filter { $0.billID == bill.id && $0.usesAmount && abs($0.dueDate.timeIntervalSince(due)) <= reach }
            .min { abs($0.dueDate.timeIntervalSince(due)) < abs($1.dueDate.timeIntervalSince(due)) }
    }

    /// What's due on a date: the statement's amount when there is one, else the bill's.
    static func amount(for bill: BillRecord, dueOn due: Date, statements: [StatementRecord]) -> Int {
        statement(for: bill, dueOn: due, statements: statements)?.amountCents ?? bill.amountCents
    }

    /// A bill's statements, newest first.
    static func history(_ billID: UUID, statements: [StatementRecord], limit: Int = 6) -> [StatementRecord] {
        Array(statements.filter { $0.billID == billID }.sorted { $0.dueDate > $1.dueDate }.prefix(limit))
    }

    /// The average of `statements`' amounts, rounded to the cent. Nil for none.
    static func average(_ statements: [StatementRecord]) -> Int? {
        guard !statements.isEmpty else { return nil }
        let total = statements.reduce(0) { $0 + $1.amountCents }
        return Int((Double(total) / Double(statements.count)).rounded())
    }

    /// Whether the charges add up to the amount due (when there are any).
    static func chargesMatch(_ charges: [StatementCharge], amountCents: Int) -> Bool {
        charges.isEmpty || charges.reduce(0) { $0 + $1.amountCents } == amountCents
    }

    /// What's still owed on the bills due in the next seven days, at their statements' amounts.
    static func dueThisWeek(_ bills: [BillRecord], payments: [EntryRecord], statements: [StatementRecord], from today: Date = .now, calendar: Calendar = .current) -> Int {
        let first = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: 7, to: first) ?? first
        return bills.reduce(0) { total, bill in
            total + BudgetMath.occurrences(of: bill, from: first, to: end, calendar: calendar)
                .filter { BudgetMath.payment(for: bill, dueOn: $0, payments: payments, calendar: calendar) == nil }
                .reduce(0) { $0 + amount(for: bill, dueOn: $1, statements: statements) }
        }
    }

    /// The bill a statement is for: one whose name matches who it's from.
    static func bill(named name: String, in bills: [BillRecord]) -> BillRecord? {
        let wanted = PayeeKey.normalized(name)
        guard !wanted.isEmpty else { return nil }
        if let named = bills.first(where: { PayeeKey.matches(wanted, PayeeKey.normalized($0.name)) }) { return named }
        // Else a distinctive word in common ("Santaquin"), never a generic one ("City", "Power").
        let theirs = Set(wanted.split(separator: " ").map(String.init)).subtracting(genericWords)
        let matches = bills.filter { bill in
            let words = Set(PayeeKey.normalized(bill.name).split(separator: " ").map(String.init)).subtracting(genericWords)
            return words.contains { $0.count > 3 && theirs.contains($0) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Words too common in billers' names to tell one from another.
    static let genericWords: Set<String> = [
        "city", "town", "county", "state", "utah", "power", "energy", "electric", "water", "utilities",
        "utility", "services", "service", "health", "bank", "insurance", "mutual", "company", "group",
        "the", "online", "billing", "bill", "payment", "payments", "account", "home", "mobile", "wireless",
        "credit", "card", "auto", "loan", "mortgage", "financial", "solutions", "systems", "communications",
    ]
}

// MARK: - Matching receipts

/// A receipt to match: who, how much, when.
nonisolated struct ReceiptCandidate: Hashable, Sendable {
    var merchant: String
    var totalCents: Int
    var date: Date
}

/// Why a match needs a look.
nonisolated enum ReceiptCheckReason: Hashable, Sendable {
    /// The charge is more than the receipt, like a tip added after it.
    case tip(differenceCents: Int)
    /// More than one charge fits; this is the closest.
    case twoCharges
    /// Same amount and store, but the charge came days later.
    case daysApart(Int)
    /// Same amount and day, but the bank's name for it is different.
    case nameDiffers

    var text: String {
        switch self {
        case .tip(let cents): "Off by \(Money.text(cents)), like a tip added after the receipt"
        case .twoCharges: "More than one charge fits; this is the closest"
        case .daysApart(let days): "Same amount, but the charge came \(days) days later"
        case .nameDiffers: "Same amount and day, but the bank names it differently"
        }
    }
}

nonisolated enum ReceiptMatch: Hashable, Sendable {
    /// Attach it without asking.
    case sure(UUID)
    /// Probably this one; ask.
    case check(UUID, ReceiptCheckReason)
    /// No transaction fits yet.
    case none
}

/// Finds the transaction a receipt belongs to. Pure, pinned by SufficeTests/BillReadingTests.
nonisolated enum ReceiptMatcher {
    /// Charges post up to a week after a purchase, and occasionally a day before the email.
    static let daysAfter = 7
    static let daysBefore = 2
    /// The most a charge can be over the receipt and still look like a tip: 30%.
    static let tipShare = 0.30

    /// The match for `receipt` among `entries`, leaving out any in `taken` (they have a receipt).
    static func match(_ receipt: ReceiptCandidate, entries: [EntryRecord], taken: Set<UUID> = [], calendar: Calendar = .current) -> ReceiptMatch {
        guard receipt.totalCents > 0 else { return .none }
        let day = calendar.startOfDay(for: receipt.date)
        func daysFrom(_ entry: EntryRecord) -> Int {
            calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: entry.date)).day ?? 0
        }
        let nearby = entries.filter { entry in
            guard entry.kind == .expense, !taken.contains(entry.id) else { return false }
            let days = daysFrom(entry)
            return days >= -daysBefore && days <= daysAfter
        }
        let name = PayeeKey.normalized(receipt.merchant)
        func sameName(_ entry: EntryRecord) -> Bool { namesMatch(name, PayeeKey.normalized(entry.payee)) }
        func closest(_ list: [EntryRecord]) -> EntryRecord? { list.min { abs(daysFrom($0)) < abs(daysFrom($1)) } }

        let exactNamed = nearby.filter { $0.amountCents == receipt.totalCents && sameName($0) }
        if exactNamed.count > 1, let best = closest(exactNamed) { return .check(best.id, .twoCharges) }
        if let only = exactNamed.first {
            let days = abs(daysFrom(only))
            return days <= 3 ? .sure(only.id) : .check(only.id, .daysApart(days))
        }

        let tipped = nearby.filter { entry in
            sameName(entry) && entry.amountCents > receipt.totalCents
                && Double(entry.amountCents - receipt.totalCents) <= Double(receipt.totalCents) * tipShare
                && abs(daysFrom(entry)) <= 3
        }
        if let best = closest(tipped) { return .check(best.id, .tip(differenceCents: best.amountCents - receipt.totalCents)) }

        let exactSameDay = nearby.filter { $0.amountCents == receipt.totalCents && abs(daysFrom($0)) <= 1 }
        if exactSameDay.count == 1, let only = exactSameDay.first { return .check(only.id, .nameDiffers) }
        return .none
    }

    /// The same business: the payee keys match, or they share a word of four letters or more
    /// ("intermountain health" and "intermountain hc").
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if PayeeKey.matches(a, b) { return true }
        let words = Set(a.split(separator: " ").filter { $0.count >= 4 })
        return b.split(separator: " ").contains { words.contains($0) }
    }
}

// MARK: - Email text

nonisolated enum EmailText {
    /// An HTML email as plain text: no tags, styles or scripts, entities decoded, one line per
    /// block, blank lines folded. Good enough for the on-device model to read a receipt.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for tag in ["style", "script", "head"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6]|/table)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</t[dh]>", with: "  ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#36;": "$", "&rsquo;": "’", "&mdash;": "—", "&ndash;": "–"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// "2026-10-20" (or "10/20/2026") as a date at noon, so a time zone never moves its day.
    static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts: [Int]
        if trimmed.contains("-") {
            parts = trimmed.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return make(year: parts[0], month: parts[1], day: parts[2], calendar: calendar)
        }
        parts = trimmed.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return make(year: parts[2] < 100 ? 2000 + parts[2] : parts[2], month: parts[0], day: parts[1], calendar: calendar)
    }

    private static func make(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}
