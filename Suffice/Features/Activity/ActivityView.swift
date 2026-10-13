import SwiftData
import SwiftUI

/// Activity: the month's transactions, newest first. "New" holds what came in on its own and
/// anything without a category, with a badge counting them; "All" is everything.
struct ActivityView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var filter: ActivityFilter = .all
    @State private var newDraft: DraftItem?

    var body: some View {
        MonthActivity(month: router.month, filter: filter)
            .id(router.month)
            .tabToolbar {
                ChoicePopoverButton(sections: filterSections) {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.white)
                }
                Button {
                    var draft = EntryDraft()
                    draft.date = router.entryDate
                    newDraft = DraftItem(draft: draft)
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                        .foregroundStyle(.white)
                }
            }
            .sheet(item: $newDraft) { item in
                TransactionSheet(entry: nil, initial: item.draft)
            }
    }

    /// The filter popover: kinds of transaction, then each person with their avatar.
    private var filterSections: [[ChoiceItem]] {
        func item(_ value: ActivityFilter, _ id: String, _ title: String, _ symbol: String?) -> ChoiceItem {
            ChoiceItem(id: id, title: title, systemImage: symbol, isSelected: filter == value) {
                withAnimation(.snappy) { filter = value }
            }
        }
        let kinds = [
            item(.all, "all", "All Transactions", "list.bullet"),
            item(.expenses, "spending", "Spending", "arrow.up.right"),
            item(.income, "income", "Income", "arrow.down.left"),
        ]
        let people = members.map { item(.member($0.id), $0.id.uuidString, $0.name, "person") }
        return people.isEmpty ? [kinds] : [kinds, people]
    }
}

/// What the list shows, from the filter menu.
enum ActivityFilter: Hashable {
    case all, expenses, income, member(UUID)

    func includes(_ entry: LedgerEntry) -> Bool {
        switch self {
        case .all: true
        case .expenses: entry.kind == .expense
        case .income: entry.kind == .income
        case .member(let id): entry.memberID == id
        }
    }
}

/// A draft wrapped for `.sheet(item:)`.
struct DraftItem: Identifiable {
    let id = UUID()
    var draft: EntryDraft
}

private enum ActivityTab: Hashable { case review, all }

private struct MonthActivity: View {
    let month: MonthSpan
    let filter: ActivityFilter
    @Query private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Environment(\.modelContext) private var context
    @State private var tab: ActivityTab = .all
    @State private var editing: LedgerEntry?

    init(month: MonthSpan, filter: ActivityFilter) {
        self.month = month
        self.filter = filter
        let start = month.start
        let end = month.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end }, sort: \.date, order: .reverse)
    }

    var body: some View {
        let lookup = Lookup(categories: categories, members: members, accounts: accounts)
        let filtered = entries.filter { filter.includes($0) }
        let toReview = filtered.filter(\.needsReview)
        let shown = tab == .review ? toReview : filtered

        GreenScreen("Activity") {
            Picker("Show", selection: $tab) {
                Text("New").tag(ActivityTab.review)
                Text("All").tag(ActivityTab.all)
            }
            .pickerStyle(.segmented)
            // The count sits at the end of the New segment. A native segment can only hold a
            // title, so the badge is drawn over it and lets taps through.
            .overlay {
                HStack(spacing: 0) {
                    HStack {
                        Spacer()
                        if toReview.count > 0 {
                            CountBadge(count: toReview.count)
                                .padding(.trailing, 10)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity)
                }
                .allowsHitTesting(false)
            }
            .accessibilityValue(toReview.count > 0 ? "\(toReview.count) new" : "")

            if shown.isEmpty {
                if tab == .review {
                    EmptyCard(systemName: "checkmark.circle", title: "All caught up", message: "Everything this month has a category.")
                } else {
                    EmptyCard(systemName: "creditcard", title: "No transactions", message: "Tap + to add what you spent or earned in \(DateLabel.month(month.start)).")
                }
            } else {
                CardList(items: shown, inset: 68) { entry in
                    Button { editing = entry } label: {
                        TransactionRow(entry: entry, lookup: lookup)
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Ledger.delete(entry, in: context)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { entry in
            TransactionSheet(entry: entry)
        }
    }
}

/// The red count bubble on New, like an app badge.
private struct CountBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.red, in: .capsule)
            .accessibilityHidden(true)
    }
}

/// One transaction: merchant avatar with who-badge, name, date and account, amount pill.
struct TransactionRow: View {
    var entry: LedgerEntry
    var lookup: Lookup

    var body: some View {
        HStack(spacing: 12) {
            MerchantAvatar(name: entry.payee, isIncome: entry.kind == .income, member: lookup.member(entry.memberID))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.payee.isEmpty ? "Untitled" : entry.payee)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountPill(cents: entry.amountCents, kind: entry.kind)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = [entry.date.formatted(.dateTime.month(.abbreviated).day())]
        if let account = lookup.account(entry.accountID) {
            parts.append(account.displayName)
        } else if entry.kind == .expense, entry.categoryID == nil {
            parts.append("Needs a category")
        } else if let category = lookup.category(entry.categoryID) {
            parts.append(category.name)
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack { ActivityView() }
        .previewEnvironment()
}
