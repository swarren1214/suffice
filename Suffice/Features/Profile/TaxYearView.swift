import SwiftData
import SwiftUI

/// Profile › Tax Year: a year of tagged spending. The total with a bar by tag and how many have
/// receipts, the transactions still missing one, each tag's total, loan interest from the
/// loans' schedules, the rules that tag transactions, and an export for a tax preparer.
struct TaxYearView: View {
    @AppStorage(SettingsKey.taxYear) private var storedYear = 0
    @Query(filter: #Predicate<LedgerEntry> { $0.taxTagRaw != "" || $0.splitsJSON != "" }, sort: \LedgerEntry.date) private var tagged: [LedgerEntry]

    private var thisYear: Int { Calendar.current.component(.year, from: .now) }

    var body: some View {
        let year = storedYear == 0 ? thisYear : min(storedYear, thisYear)
        TaxYearContent(year: year)
            .id(year)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ChoicePopoverButton(sections: [years.map { option in
                        ChoiceItem(id: "\(option)", title: String(option), isSelected: option == year) { storedYear = option }
                    }]) {
                        HStack(spacing: 4) {
                            Text(String(year))
                            Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Year, \(String(year))")
                }
            }
    }

    /// This year and every earlier year with tagged spending, newest first.
    private var years: [Int] {
        let calendar = Calendar.current
        let first = tagged.first.map { calendar.component(.year, from: $0.date) } ?? thisYear
        return Array((min(first, thisYear)...thisYear).reversed())
    }
}

private struct TaxYearContent: View {
    let year: Int
    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @Query(filter: #Predicate<PayeeRule> { $0.taxTagRaw != "" }) private var rules: [PayeeRule]
    @State private var addsRule = false
    @State private var removing: RuleLine?
    @State private var exportFiles: [URL] = []
    @State private var preparing = false

    init(year: Int) {
        self.year = year
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? .distantFuture
        _entries = Query(
            filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end && ($0.taxTagRaw != "" || $0.splitsJSON != "") },
            sort: \LedgerEntry.date,
            order: .reverse
        )
    }

    private var isThisYear: Bool { year == Calendar.current.component(.year, from: .now) }

    var body: some View {
        let report = makeReport()
        let lookup = Lookup(categories: categories, members: members, accounts: accounts)
        let missing = TaxMath.missingReceipts(report.items)

        GreenScreen("Tax Year") {
            SummaryCard(report: report)

            if !missing.isEmpty {
                NavigationLink {
                    TaxTransactionsView(title: "Without a Receipt", items: missing)
                } label: {
                    MissingReceiptsRow(count: missing.count, byTag: TaxMath.missingByTag(report.items), isThisYear: isThisYear)
                }
                .buttonStyle(.plain)
            }

            SectionTitle("By tag")
            if report.summary.tags.isEmpty {
                EmptyCard(systemName: "tag", title: "Nothing tagged in \(String(year))", message: "Tag a transaction for taxes on its sheet, or give a budget a tag (Giving → Charitable giving), and it adds up here.")
            } else {
                CardList(items: report.summary.tags, inset: 60) { line in
                    NavigationLink {
                        TaxTransactionsView(title: line.tag.name, items: report.items.filter { $0.tag == line.tag })
                    } label: {
                        TagRow(line: line, items: report.items.filter { $0.tag == line.tag })
                    }
                    .buttonStyle(.plain)
                }
            }

            if !report.interest.isEmpty {
                SectionTitle("From your accounts")
                CardList(items: report.interest, inset: 60) { line in
                    HStack(spacing: 12) {
                        WealthIcon(symbol: line.symbol, color: line.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title)
                            Text("\(line.lender.isEmpty ? "" : "\(line.lender) · ")from the loan’s schedule")
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Text(Money.whole(line.cents))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 62)
                    .accessibilityElement(children: .combine)
                }
                Text("Your lender’s Form 1098 is the official figure.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 6)
            }

            SectionTitle(title: "Rules") {
                TintedCapsuleButton(title: "Add", systemImage: "plus") { addsRule = true }
                    .accessibilityLabel("Add a rule")
            }
            let ruleLines = self.ruleLines()
            if ruleLines.isEmpty {
                Card {
                    Text("Rules tag new transactions on their own: a budget (Giving is always charitable) or a payee (Walgreens is HSA eligible).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                CardList(items: ruleLines) { line in
                    HStack {
                        Text(line.title).lineLimit(1)
                        Spacer(minLength: 8)
                        TaxTagPill(tag: line.tag, short: true)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                    .contextMenu {
                        Button("Remove Rule", menuIcon: "trash", role: .destructive) { removing = line }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Remove Rule") { removing = line }
                }
            }

            ShareLink(items: exportFiles) {
                Label(preparing ? "Preparing…" : "Share With Your Tax Preparer", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                    .background(Brand.green, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(exportFiles.isEmpty)
            .opacity(exportFiles.isEmpty ? 0.6 : 1)
            .padding(.top, 4)

            Text("A PDF summary by tag, a spreadsheet of every transaction, and the receipts, from your \(DeviceName.current)’s share sheet. Suffice doesn’t give tax advice.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
        }
        .refreshable { await HouseholdSync.shared.syncNow() }
        .task(id: exportKey(report)) {
            preparing = true
            // Off the first frame, so the screen shows before the files are written.
            await Task.yield()
            exportFiles = TaxExport.files(for: report, lookup: lookup, receipts: receipts(for: report))
            preparing = false
        }
        .sheet(isPresented: $addsRule) {
            TaxRuleEditor()
        }
        .alert("Remove this rule?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { line in
            Button("Remove Rule", role: .destructive) { remove(line) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Transactions already tagged keep their tags. New ones won’t be tagged on their own.")
        }
    }

    // MARK: The year

    private func makeReport() -> TaxReport {
        let sources = entries.compactMap { entry -> TaxSource? in
            let record = entry.record
            let anyTag = record.taxTag.isTagged || record.splits.contains { $0.taxTag?.isTagged == true }
            guard anyTag, record.kind == .expense else { return nil }
            return TaxSource(entry: record, hasReceipt: entry.receiptData != nil, note: entry.note)
        }
        let items = TaxMath.items(sources, year: year)
        return TaxReport(year: year, isThisYear: isThisYear, items: items, summary: TaxMath.summary(items), interest: interestLines())
    }

    /// Mortgage, home equity and student loan interest for the year (to today, this year).
    private func interestLines() -> [LoanInterestLine] {
        let calendar = Calendar.current
        let kinds: Set<LoanKind> = [.mortgage, .homeEquity, .student]
        return loans.compactMap { loan -> LoanInterestLine? in
            guard kinds.contains(loan.kind) else { return nil }
            var cents = LoanMath.interestPaid(loan.record, inYear: year, calendar: calendar)
            if isThisYear, let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) {
                cents = LoanMath.interestPaid(loan.record, through: .now, calendar: calendar)
                    - LoanMath.interestPaid(loan.record, through: start.addingTimeInterval(-1), calendar: calendar)
            }
            guard cents > 0 else { return nil }
            return LoanInterestLine(id: loan.id, title: "\(loan.kind == .student ? "Student loan" : loan.kind == .homeEquity ? "Home equity" : "Mortgage") interest", lender: loan.lender, symbol: loan.symbol, color: loan.color, cents: cents)
        }
    }

    private func receipts(for report: TaxReport) -> [UUID: Data] {
        let ids = Set(report.items.filter(\.hasReceipt).map(\.entryID))
        var result: [UUID: Data] = [:]
        for entry in entries where ids.contains(entry.id) {
            if let data = entry.receiptData { result[entry.id] = data }
        }
        return result
    }

    /// Changes when anything in the export would.
    private func exportKey(_ report: TaxReport) -> String {
        "\(year)|\(report.summary.totalCents)|\(report.items.count)|\(report.summary.withReceipt)|\(report.interest.map(\.cents))|\(report.summary.tags.map { "\($0.tag.rawValue):\($0.totalCents)" })"
    }

    // MARK: Rules

    struct RuleLine: Identifiable, Hashable {
        enum Source: Hashable { case budget(UUID), payee(UUID) }
        var source: Source
        var title: String
        var tag: TaxTag
        var id: Source { source }
    }

    /// Budgets with a tag, then payee rules, by name.
    private func ruleLines() -> [RuleLine] {
        let lookup = Lookup(categories: categories)
        let budgets = categories
            .filter { $0.taxTag.isTagged && !$0.isArchived }
            .map { category -> RuleLine in
                let name = category.parentID == nil ? category.name : "\(lookup.budget(for: category.id)?.name ?? "") › \(category.name)"
                return RuleLine(source: .budget(category.id), title: "\(name) budget", tag: category.taxTag)
            }
        let names = payeeNames()
        let payees = rules
            .filter { $0.taxTag.isTagged }
            .map { RuleLine(source: .payee($0.id), title: names[$0.payeeKey] ?? $0.payeeKey.capitalized, tag: $0.taxTag) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return budgets + payees
    }

    /// A rule keeps the payee lowercased; show it as recent transactions spelled it.
    private func payeeNames() -> [String: String] {
        guard !rules.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 300
        var names: [String: String] = [:]
        for entry in (try? context.fetch(descriptor)) ?? [] {
            let key = PayeeRule.key(for: entry.payee)
            if names[key] == nil { names[key] = entry.payee }
        }
        return names
    }

    private func remove(_ line: RuleLine) {
        switch line.source {
        case .budget(let id):
            categories.first { $0.id == id }?.taxTag = .untagged
        case .payee(let id):
            if let rule = rules.first(where: { $0.id == id }) {
                rule.taxTag = .untagged
                if rule.isEmpty { context.delete(rule) }
            }
        }
        try? context.save()
    }
}

// MARK: - Pieces

/// The glass card: the year's tagged total, a bar by tag, transactions and receipts.
private struct SummaryCard: View {
    var report: TaxReport

    var body: some View {
        let summary = report.summary
        GlassCard {
            GlassCardHeader(title: "Tagged for taxes", note: report.isThisYear ? "Jan 1 – today" : "Jan 1 – Dec 31")
            GlassFigure(text: Money.whole(summary.totalCents))
            if summary.totalCents > 0 {
                TagBar(lines: summary.tags)
            }
            HStack(spacing: 10) {
                GlassTile(title: "Transactions", value: "\(summary.transactions)")
                GlassTile(title: "With a receipt", value: "\(summary.withReceipt) of \(summary.transactions)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Each tag's share of the year, in its color.
private struct TagBar: View {
    var lines: [TaxTagTotal]

    var body: some View {
        let total = max(lines.reduce(0) { $0 + $1.totalCents }, 1)
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let width = max(proxy.size.width - spacing * CGFloat(max(lines.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(lines) { line in
                    Rectangle()
                        .fill(line.tag.color.color)
                        .frame(width: max(width * CGFloat(line.totalCents) / CGFloat(total), 3))
                }
            }
        }
        .frame(height: 10)
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.map { "\($0.tag.name) \(Int((Double($0.totalCents) / Double(total) * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

/// "7 without a receipt · 5 medical, 2 business · scan them while you still have them".
private struct MissingReceiptsRow: View {
    var count: Int
    var byTag: [(tag: TaxTag, count: Int)]
    var isThisYear: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "receipt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CategoryColor.orange.ink)
                .frame(width: 36, height: 36)
                .background(CategoryColor.orange.tint, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) without a receipt")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .contentShape(.rect(cornerRadius: 26))
    }

    private var detail: String {
        let tags = byTag.map { "\($0.count) \($0.tag.shortName.lowercased())" }.joined(separator: ", ")
        return isThisYear ? "\(tags) · scan them while you still have them" : tags
    }
}

/// One tag's year: its icon, name, how many and their receipts, and its total.
private struct TagRow: View {
    var line: TaxTagTotal
    var items: [TaxItem]

    var body: some View {
        HStack(spacing: 12) {
            TaxTagIcon(tag: line.tag, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.tag.name).foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 8)
            Text(Money.whole(line.totalCents))
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .contentShape(.rect)
    }

    private var detail: String {
        let count = "\(line.count) transaction\(line.count == 1 ? "" : "s")"
        switch line.missingReceipts {
        case 0: return "\(count) · all with receipts"
        case 1: return "\(count) · 1 needs a receipt"
        default: return "\(count) · \(line.missingReceipts) need a receipt"
        }
    }
}

// MARK: - Transactions

/// A list of tagged transactions (a tag's, or the ones without a receipt). Tapping one opens it.
struct TaxTransactionsView: View {
    var title: String
    var items: [TaxItem]
    @Query private var entries: [LedgerEntry]
    @State private var opened: LedgerEntry?

    init(title: String, items: [TaxItem]) {
        self.title = title
        self.items = items
        let ids = Array(Set(items.map(\.entryID)))
        _entries = Query(filter: #Predicate<LedgerEntry> { ids.contains($0.id) })
    }

    var body: some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        List {
            Section {
                ForEach(items) { item in
                    Button {
                        opened = byID[item.entryID]
                    } label: {
                        HStack(spacing: 12) {
                            MerchantAvatar(name: item.payee, size: 40, logoURL: byID[item.entryID]?.logoURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.payee).foregroundStyle(.primary).lineLimit(1)
                                Text("\(DateLabel.short(item.date)) · \(item.tag.shortName)\(item.isPart ? " · part of a split" : "")")
                                    .font(.caption)
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Spacer(minLength: 8)
                            if !item.hasReceipt {
                                Image(systemName: "receipt")
                                    .foregroundStyle(CategoryColor.orange.ink)
                                    .accessibilityLabel("No receipt")
                            }
                            Text(Money.text(item.cents))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                        }
                    }
                }
            } footer: {
                Text("\(Money.text(items.reduce(0) { $0 + $1.cents })) in all.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await HouseholdSync.shared.syncNow() }
        .sheet(item: $opened) { entry in
            TransactionSheet(entry: entry)
        }
    }
}

// MARK: - Adding a rule

/// Tax Year › Rules › Add: tag a payee's transactions, or a budget's, from now on.
struct TaxRuleEditor: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case payee, budget
        var id: String { rawValue }
        var title: String { self == .payee ? "A Payee" : "A Budget" }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @State private var kind: Kind = .payee
    @State private var payee = ""
    @State private var categoryID: UUID?
    @State private var tag: TaxTag = .medical
    @State private var earlier: [LedgerEntry] = []
    @State private var asksAboutEarlier = false

    private var isValid: Bool {
        kind == .payee ? !payee.trimmingCharacters(in: .whitespaces).isEmpty : categoryID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tag", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    if kind == .payee {
                        TextField("Payee, like Walgreens", text: $payee)
                            .textInputAutocapitalization(.words)
                    } else {
                        CategoryPicker(title: "Budget", selection: $categoryID, choices: CategoryChoice.budgetsAndSubcategories(categories), noneTitle: "Choose")
                    }
                    Picker("As", selection: $tag) {
                        ForEach(TaxTag.tags) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(kind == .payee
                         ? "New transactions from this payee get the tag, unless you tag one yourself."
                         : "New transactions in this budget get the tag, unless a payee rule or you tag one otherwise.")
                }
            }
            .navigationTitle("New Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Add") { save() }
                        .disabled(!isValid)
                }
            }
            .alert("Tag \(earlier.count) earlier transaction\(earlier.count == 1 ? "" : "s") from this year too?", isPresented: $asksAboutEarlier) {
                Button("Tag Them") {
                    for entry in earlier { entry.taxTag = tag }
                    try? context.save()
                    dismiss()
                }
                Button("Not Now", role: .cancel) { dismiss() }
            } message: {
                Text("They’d be tagged \(tag.name).")
            }
        }
    }

    private func save() {
        switch kind {
        case .payee:
            let name = payee.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rule = Ledger.rule(for: name, in: context) {
                rule.taxTag = tag
            } else {
                context.insert(PayeeRule(payee: name, categoryID: nil, taxTag: tag))
            }
            earlier = Ledger.untaggedThisYear(payee: name, in: context)
        case .budget:
            guard let category = categories.first(where: { $0.id == categoryID }) else { return }
            category.taxTag = tag
            let ids = Set([category.id] + categories.filter { $0.parentID == category.id }.map(\.id))
            earlier = Ledger.untaggedThisYear(in: ids, context: context)
        }
        try? context.save()
        if earlier.isEmpty {
            dismiss()
        } else {
            asksAboutEarlier = true
        }
    }
}

#Preview {
    NavigationStack { TaxYearView() }
        .previewEnvironment()
}
