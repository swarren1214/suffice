import SwiftData
import SwiftUI

/// The round search button: every transaction, any month, by merchant, budget, person,
/// account or note.
struct SearchView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var query = ""
    @State private var editing: LedgerEntry?

    var body: some View {
        let lookup = Lookup(categories: categories, members: members, accounts: accounts)
        let results = matches(lookup)

        GreenScreen("Search") {
            if results.isEmpty {
                if query.isEmpty {
                    EmptyCard(systemName: "magnifyingglass", title: "Search everything", message: "Find any transaction by merchant, budget, person, account or note.", isGlass: true)
                } else {
                    EmptyCard(systemName: "magnifyingglass", title: "No results", message: "Nothing matches “\(query)”.", isGlass: true)
                }
            } else {
                Text(query.isEmpty ? "Recent" : "\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                CardList(items: results, inset: 68) { entry in
                    Button { editing = entry } label: {
                        TransactionRow(entry: entry, lookup: lookup)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Merchants, budgets, notes")
        .sheet(item: $editing) { entry in
            TransactionSheet(entry: entry)
        }
    }

    private func matches(_ lookup: Lookup) -> [LedgerEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return Array(entries.prefix(20)) }
        return entries.filter { entry in
            let fields = [
                entry.payee,
                entry.note,
                lookup.category(entry.categoryID)?.name ?? "",
                lookup.budget(for: entry.categoryID)?.name ?? "",
                lookup.member(entry.memberID)?.name ?? "",
                lookup.account(entry.accountID)?.displayName ?? "",
                Money.text(entry.amountCents),
            ]
            return fields.contains { $0.localizedStandardContains(text) }
        }
        .prefix(200)
        .map { $0 }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .previewEnvironment()
}
