import Foundation
import SwiftData

/// Suffice's money as HearthMoney's values, for Ember on this iPhone: `suffice.money.json` in the
/// Hearth app group. Ember answers from it before its own iCloud copy, so it sees exactly what
/// Suffice shows (bank transactions included) the moment Suffice has them, with nothing to
/// decrypt or download. Ember's copy of this type has the same kind and shape.
nonisolated struct SufficeMoneyPublication: HearthPublication {
    static let kind = "money"
    static let version = 1
    var book: HearthMoney.Book
}

enum SufficeMoneyPublisher {
    /// How far back transactions go: a little over a year ("this time last year", "since May").
    static let days = 400

    private static var writing: Task<Void, Never>?

    /// Writes the file after every save (with the widgets), on opening and on leaving. The book
    /// is built here; encoding and writing happen off the main thread.
    @MainActor
    static func publish(_ context: ModelContext, now: Date = .now) {
        guard !ScreenshotMode.isOn else { return }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= since }))) ?? []
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter(\.isActive)
        let members = (try? context.fetch(FetchDescriptor<Member>())) ?? []
        let book = HearthMoney.Book(
            categories: categories.map(\.record.money),
            entries: entries.map { entry in
                var money = entry.record.money
                money.place = entry.placeName
                return money
            },
            bills: bills.map(\.record.money),
            members: members.map { HearthMoney.Member(id: $0.id, name: $0.name) }
        )
        let previous = writing
        writing = Task.detached(priority: .utility) {
            await previous?.value
            Hearth.publish(SufficeMoneyPublication(book: book), from: .suffice)
        }
    }

    /// Signing out or erasing: Ember shouldn't keep reading it.
    static func remove() {
        Hearth.remove(SufficeMoneyPublication.self, from: .suffice)
    }
}
