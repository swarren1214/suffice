import Foundation
import SwiftData

/// Allowance Caloma paid out on payday (through the Hearth app group, `HearthAllowance`),
/// brought into Suffice as expenses to review: "Allowance: Emma", $5, waiting in Review.
///
/// Each payout comes in once. Its id is kept as the entry's `externalID`, so two devices
/// importing the same payout are merged like a bank transaction (`CloudSync.mergeBankEntries`),
/// and the ids already imported are remembered so a deleted one doesn't come back.
enum CalomaAllowance {
    static let idPrefix = "caloma-allowance:"
    private static let importedKey = "hearth.calomaAllowance.imported"
    /// Payouts before this aren't imported: on first run, the week before Suffice first looked.
    private static let sinceKey = "hearth.calomaAllowance.since"

    static func importPayouts(in context: ModelContext, now: Date = .now) {
        guard !ScreenshotMode.isOn,
              let allowance = Hearth.read(HearthAllowance.self, from: .caloma)?.value else { return }
        let defaults = UserDefaults.standard
        let since: Date
        if let stored = defaults.object(forKey: sinceKey) as? Date {
            since = stored
        } else {
            since = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            defaults.set(since, forKey: sinceKey)
        }
        var imported = Set(defaults.stringArray(forKey: importedKey) ?? [])
        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID != nil }))) ?? [])
            .compactMap(\.externalID)
            .filter { $0.hasPrefix(idPrefix) })
        let category = allowanceCategory(in: context)

        var added = 0
        for payout in allowance.payouts where payout.date >= since && payout.cents > 0 {
            let externalID = idPrefix + payout.id
            guard !imported.contains(payout.id), !existing.contains(externalID) else {
                imported.insert(payout.id)
                continue
            }
            let entry = LedgerEntry(
                date: payout.date,
                payee: "Allowance: \(payout.name)",
                amountCents: payout.cents,
                kind: .expense,
                categoryID: category?.id,
                note: "Paid in Caloma",
                isReviewed: false
            )
            entry.externalID = externalID
            context.insert(entry)
            imported.insert(payout.id)
            added += 1
        }
        // Keep the list from growing forever: only ids Caloma still shares need remembering.
        let current = Set(allowance.payouts.map(\.id))
        defaults.set(Array(imported.intersection(current)), forKey: importedKey)
        if added > 0 { try? context.save() }
    }

    /// A budget named for allowance or kids, if the household has one.
    private static func allowanceCategory(in context: ModelContext) -> BudgetCategory? {
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        return categories.first { !$0.isArchived && $0.name.lowercased().contains("allowance") }
            ?? categories.first { !$0.isArchived && $0.name.lowercased().contains("kids") }
    }
}
