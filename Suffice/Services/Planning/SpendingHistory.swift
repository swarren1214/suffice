import Foundation
import SwiftData

/// What the bank history on this device says about how the household spends: the averages
/// behind onboarding's suggested plan, and the bills hiding in it.
///
/// Only bank-synced transactions count, because only they carry Plaid's category (see
/// `LedgerEntry.bankCategory`). Hand-entered ones and a partner's (which arrive without one)
/// are left out. Pure functions over snapshots, so it's all testable.
nonisolated enum SpendingHistory {
    /// A bank transaction, as a plain snapshot.
    struct Item: Hashable, Sendable {
        var id: UUID
        var date: Date
        var payee: String
        var amountCents: Int
        var isIncome: Bool
        /// Plaid's category: detailed ("RENT_AND_UTILITIES_RENT") or primary ("FOOD_AND_DRINK").
        var category: String?
    }

    /// How far back the averages look. Plaid's first sync brings about this much.
    static let lookback: TimeInterval = 92 * 86_400

    /// A budget onboarding suggests that the starter budgets don't have.
    static let shopping = (name: "Shopping", symbol: "bag", color: CategoryColor.pink)

    // MARK: Categories

    /// Which starter budget a Plaid category belongs in, by the budget's name. Nil for money
    /// that isn't spending (transfers, card payments) or that no starter budget covers.
    static func budgetName(for category: String?) -> String? {
        guard let category else { return nil }
        if isMovingMoney(category) { return nil }
        let rules: [(String, String)] = [
            ("RENT_AND_UTILITIES_RENT", "Home"),
            ("LOAN_PAYMENTS_MORTGAGE_PAYMENT", "Home"),
            ("HOME_IMPROVEMENT", "Home"),
            ("RENT_AND_UTILITIES", "Utilities"),
            ("FOOD_AND_DRINK", "Food"),
            ("LOAN_PAYMENTS_CAR_PAYMENT", "Auto"),
            ("TRANSPORTATION", "Auto"),
            ("GENERAL_SERVICES_AUTOMOTIVE", "Auto"),
            ("GENERAL_SERVICES_INSURANCE", "Auto"),
            ("ENTERTAINMENT", "Entertainment"),
            ("GOVERNMENT_AND_NON_PROFIT_DONATIONS", "Giving"),
            ("GENERAL_MERCHANDISE", shopping.name),
        ]
        return rules.first { category.hasPrefix($0.0) }?.1
    }

    /// Money moving between accounts rather than being spent or earned.
    static func isMovingMoney(_ category: String) -> Bool {
        category.hasPrefix("TRANSFER_") || category == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
    }

    static func isPaycheck(_ item: Item) -> Bool {
        guard item.isIncome else { return false }
        guard let category = item.category else { return true }
        return category.hasPrefix("INCOME")
    }

    // MARK: Averages

    /// How many months `items` cover, from the oldest one in the lookback to now: 1 to 3.
    static func months(_ items: [Item], now: Date = .now) -> Double {
        let start = now.addingTimeInterval(-lookback)
        guard let oldest = items.filter({ $0.date >= start }).map(\.date).min() else { return 1 }
        let days = now.timeIntervalSince(oldest) / 86_400
        return min(max(days / 30.44, 1), 3)
    }

    /// Average monthly spending per budget name.
    static func monthlySpending(_ items: [Item], now: Date = .now) -> [String: Int] {
        let start = now.addingTimeInterval(-lookback)
        let span = months(items, now: now)
        var totals: [String: Int] = [:]
        for item in items where !item.isIncome && item.date >= start {
            guard let name = budgetName(for: item.category) else { continue }
            totals[name, default: 0] += item.amountCents
        }
        return totals.mapValues { Int((Double($0) / span).rounded()) }
    }

    /// Average monthly take-home pay.
    static func monthlyIncome(_ items: [Item], now: Date = .now) -> Int {
        let start = now.addingTimeInterval(-lookback)
        let total = items.filter { $0.date >= start && isPaycheck($0) }.reduce(0) { $0 + $1.amountCents }
        return Int((Double(total) / months(items, now: now)).rounded())
    }

    /// A tidy amount to suggest: to the nearest $10, or $50 from $1,000 up.
    static func suggestion(for averageCents: Int) -> Int {
        guard averageCents > 0 else { return 0 }
        let step = averageCents >= 100_000 ? 5_000 : 1_000
        return max(step, Int((Double(averageCents) / Double(step)).rounded()) * step)
    }

    // MARK: Finding bills

    /// A repeating payment that looks like a bill or subscription.
    struct FoundBill: Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String
        /// The usual amount: the median payment.
        var amountCents: Int
        var isVariable: Bool
        var minCents: Int?
        var maxCents: Int?
        var dueDay: Int
        /// The first payment seen, which anchors the bill's schedule.
        var firstDate: Date
        /// The starter budget it belongs in, by name.
        var budgetName: String?
        var isSubscription: Bool
        /// The transactions that paid it, so they can be linked to the bill.
        var entryIDs: [UUID]
    }

    /// Payees paid about once a month, at least twice and recently, for a steady amount (or one
    /// that moves within a range, like power). Groceries, gas and shopping never count, nor
    /// anything already a bill (by name). Biggest first.
    static func findBills(_ items: [Item], existingNames: [String] = [], now: Date = .now, calendar: Calendar = .current) -> [FoundBill] {
        let start = now.addingTimeInterval(-lookback - 14 * 86_400)
        let existing = existingNames.map(PayeeKey.normalized)
        let candidates = items.filter { item in
            guard !item.isIncome, item.date >= start, item.amountCents > 0 else { return false }
            guard let category = item.category else { return true }
            return !isMovingMoney(category) && !neverBills.contains { category.hasPrefix($0) }
        }
        let groups = Dictionary(grouping: candidates) { PayeeKey.normalized($0.payee) }

        var found: [FoundBill] = []
        for (key, group) in groups where !key.isEmpty && group.count >= 2 {
            guard !existing.contains(where: { PayeeKey.matches(key, $0) }) else { continue }
            let sorted = group.sorted { $0.date < $1.date }
            // About monthly: every payment 20 to 40 days after the one before, and the last one
            // within the past 45 days.
            let gaps = zip(sorted, sorted.dropFirst()).map { $1.date.timeIntervalSince($0.date) / 86_400 }
            guard gaps.allSatisfy({ (20.0...40.0).contains($0) }) else { continue }
            guard let last = sorted.last, now.timeIntervalSince(last.date) < 45 * 86_400 else { continue }

            let amounts = sorted.map(\.amountCents).sorted()
            let median = amounts[amounts.count / 2]
            guard let low = amounts.first, let high = amounts.last, median > 0 else { continue }
            let isSteady = high - low <= max(100, median * 3 / 100)
            let inRange = Double(low) >= Double(median) * 0.5 && Double(high) <= Double(median) * 1.5
            guard isSteady || inRange else { continue }

            let category = last.category
            found.append(FoundBill(
                name: last.payee.trimmingCharacters(in: .whitespacesAndNewlines),
                amountCents: median,
                isVariable: !isSteady,
                minCents: isSteady ? nil : low,
                maxCents: isSteady ? nil : high,
                dueDay: calendar.component(.day, from: last.date),
                firstDate: sorted[0].date,
                budgetName: budgetName(for: category),
                isSubscription: isSubscription(payee: key, category: category),
                entryIDs: sorted.map(\.id)
            ))
        }
        return Array(found.sorted { $0.amountCents > $1.amountCents }.prefix(10))
    }

    /// Spending that repeats without being a bill.
    private static let neverBills = [
        "FOOD_AND_DRINK", "GENERAL_MERCHANDISE", "TRANSPORTATION_GAS", "TRANSPORTATION_PUBLIC_TRANSIT",
        "TRANSPORTATION_TAXIS_AND_RIDE_SHARES", "TRANSPORTATION_PARKING", "TRAVEL", "PERSONAL_CARE_HAIR_AND_BEAUTY",
        "BANK_FEES_ATM_FEES", "MEDICAL_PHARMACIES_AND_SUPPLEMENTS",
    ]

    private static let subscriptionNames = [
        "netflix", "spotify", "hulu", "disney", "youtube", "hbo", "max", "peacock", "paramount",
        "apple", "audible", "prime video", "amazon prime", "sirius", "pandora", "crunchyroll", "nyt", "new york times",
    ]

    static func isSubscription(payee key: String, category: String?) -> Bool {
        if let category, category.hasPrefix("ENTERTAINMENT_TV_AND_MOVIES") || category.hasPrefix("ENTERTAINMENT_MUSIC_AND_AUDIO") {
            return true
        }
        return subscriptionNames.contains { key == $0 || key.hasPrefix($0 + " ") }
    }
}

/// Payee names, loosened for matching: "NETFLIX.COM 866-579", "Netflix" → "netflix".
nonisolated enum PayeeKey {
    static func normalized(_ payee: String) -> String {
        payee.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 1 && !noise.contains($0) }
            .prefix(3)
            .joined(separator: " ")
    }

    private static let noise: Set<String> = ["com", "net", "www", "inc", "llc", "co", "pos", "ach", "debit", "purchase", "payment"]

    /// The same payee: equal, or one starts with the other ("verizon" and "verizon wireless").
    static func matches(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }
}

// MARK: - From the store

@MainActor
extension SpendingHistory {
    /// This device's bank transactions: the ones with Plaid's category. (A partner's arrive
    /// through iCloud without it.)
    static func items(in context: ModelContext) -> [Item] {
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID != nil && $0.bankCategory != nil })
        return ((try? context.fetch(descriptor)) ?? []).map { entry in
            Item(id: entry.id, date: entry.date, payee: entry.payee, amountCents: entry.amountCents, isIncome: entry.kind == .income, category: entry.bankCategory)
        }
    }
}
