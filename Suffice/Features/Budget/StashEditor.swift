import SwiftData
import SwiftUI

/// The editable fields of a stash, before it's saved.
struct StashDraft: Equatable {
    var name = ""
    var symbol = "star"
    var color: CategoryColor = .green
    var targetCents = 0
    var dueDate: Date = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    var repeatsYearly = true
    var openingCents = 0
    var accountID: UUID?
    var billID: UUID?
    var countsAutomatically = true
    var isEssential = false

    init() {}

    init(_ stash: Stash) {
        name = stash.name
        symbol = stash.symbol
        color = stash.color
        targetCents = stash.targetCents
        dueDate = stash.dueDate
        repeatsYearly = stash.repeatsYearly
        openingCents = stash.openingCents
        accountID = stash.accountID
        billID = stash.billID
        countsAutomatically = stash.countsAutomatically
        isEssential = stash.isEssential
    }

    /// For a bill: its amount by its next due date, repeating when the bill comes yearly.
    static func forBill(_ bill: Bill, due: Date) -> StashDraft {
        var draft = StashDraft()
        draft.name = bill.name
        draft.symbol = "doc.text"
        draft.color = bill.color
        draft.targetCents = bill.amountCents
        draft.dueDate = due
        draft.billID = bill.id
        draft.repeatsYearly = bill.frequency == .yearly && bill.interval <= 1
        return draft
    }

    /// From the emergency fund's gap: the rest of the goal, over a year, once.
    static func emergencyFund(gapCents: Int, accountID: UUID?) -> StashDraft {
        var draft = StashDraft()
        draft.name = "Emergency fund"
        draft.symbol = "shield"
        draft.color = .orange
        draft.targetCents = gapCents
        draft.dueDate = Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now
        draft.repeatsYearly = false
        draft.accountID = accountID
        return draft
    }

    var isValid: Bool { targetCents > 0 && !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// A stash or a new one to open in the stash sheet.
struct StashSheetItem: Identifiable {
    let id = UUID()
    var stash: Stash?
    var draft: StashDraft
}

/// A stash: what it's for, the amount each month and how it builds until it's due, then the
/// details (amount, due date, repeats, what's already stashed, the account it sits in, and
/// whether it counts on the 1st on its own). From Budget › Stashes, a bill, or the emergency
/// fund's gap.
struct StashEditor: View {
    /// Nil to create one from `initial`.
    let stash: Stash?
    var initial: StashDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var bills: [Bill]
    @Query private var moves: [StashMove]
    @Query(filter: #Predicate<LedgerEntry> { $0.stashID != nil }) private var paid: [LedgerEntry]

    @State private var draft = StashDraft()
    @State private var targetText = ""
    @State private var openingText = ""
    @State private var loaded = false
    @State private var pickingLook = false
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?

    private enum Field { case name, target, opening }

    init(stash: Stash?, initial: StashDraft = StashDraft()) {
        self.stash = stash
        self.initial = initial
    }

    private var bill: Bill? { bills.first { $0.id == draft.billID } }

    /// The stash as it would be with these changes.
    private var preview: StashRecord {
        StashRecord(
            id: stash?.id ?? UUID(),
            name: draft.name,
            targetCents: draft.targetCents,
            dueDate: draft.dueDate,
            repeatsYearly: draft.repeatsYearly,
            openingCents: draft.openingCents,
            billID: draft.billID,
            countsAutomatically: draft.countsAutomatically,
            isEssential: draft.isEssential,
            createdAt: stash?.createdAt ?? .now
        )
    }

    var body: some View {
        let summary = StashMath.summary(preview, moves: moves.map(\.record), entries: paid.map(\.record))

        NavigationStack {
            Form {
                header
                monthlySection(summary)
                detailsSection
                whenDueSection
                if let stash {
                    existingSection(stash, summary: summary)
                }
            }
            .navigationTitle(stash == nil ? "New Stash" : "Stash")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton(stash == nil ? "Add" : "Save") { save() }
                        .disabled(!draft.isValid)
                }
            }
            .alert("Delete this stash?", isPresented: $confirmsDelete) {
                Button("Delete Stash", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The money stays wherever it is. Suffice stops counting it, and anything it paid for counts in that month’s budget again.")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Button { pickingLook = true } label: {
                    Image(systemName: draft.symbol)
                        .symbolVariant(.fill)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(draft.color.ink)
                        .frame(width: 56, height: 56)
                        .background(draft.color.tint, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Icon and color")
                .hearthIconColorPicker(
                    isPresented: $pickingLook,
                    title: draft.name.isEmpty ? "New stash" : draft.name,
                    caption: "Stash",
                    context: .bill,
                    icon: $draft.symbol,
                    color: $draft.color.hearthChoice
                )
                VStack(alignment: .leading, spacing: 2) {
                    TextField("What it's for", text: $draft.name)
                        .font(.title2.bold())
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .name)
                    Text(origin)
                        .font(.footnote)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    /// "Stash each month": the amount, a bar for each month until it's due, and what it adds up to.
    private func monthlySection(_ summary: StashSummary) -> some View {
        let funded = summary.status == .funded
        return Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Stash each month").fontWeight(.semibold)
                    Spacer()
                    if !funded, summary.monthsLeft > 0 {
                        Text(summary.monthsLeft == 1 ? "1 month to go" : "\(summary.monthsLeft) months to go")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text(funded ? "Fully stashed" : Money.whole(summary.monthlyCents))
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(CategoryColor.green.ink)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                if !funded, summary.monthsLeft > 1 {
                    StashScheduleBars(months: scheduleMonths(summary), dueMonth: MonthSpan(containing: draft.dueDate).start)
                }

                Text(summaryText(summary))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .animation(.snappy, value: summary.monthlyCents)
            .accessibilityElement(children: .combine)
        }
    }

    private var detailsSection: some View {
        Section {
            LabeledContent("Amount needed") {
                TextField(Money.text(0), text: $targetText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .target)
                    .currencyEditing($targetText, isFocused: focus == .target)
                    .onChange(of: targetText) { _, value in draft.targetCents = Money.cents(from: value) ?? 0 }
            }
            DatePicker("Due", selection: $draft.dueDate, displayedComponents: .date)
            Picker("Repeats", selection: $draft.repeatsYearly) {
                Text("Every year").tag(true)
                Text("Just once").tag(false)
            }
            .pickerStyle(.segmented)
            LabeledContent(stash == nil ? "Already stashed" : "Stashed before it started") {
                TextField(Money.text(0), text: $openingText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .opening)
                    .currencyEditing($openingText, isFocused: focus == .opening)
                    .onChange(of: openingText) { _, value in draft.openingCents = Money.cents(from: value) ?? 0 }
            }
            Picker("Kept in", selection: $draft.accountID) {
                Text("Not set").tag(UUID?.none)
                ForEach(accounts.filter { $0.kind != .credit }) { account in
                    Text(account.displayName).tag(UUID?.some(account.id))
                }
            }
            .pickerStyle(.navigationLink)
            Toggle(isOn: $draft.countsAutomatically) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Count it on the 1st")
                    Text("Adds this month’s amount on its own. Off: you mark it each month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $draft.isEssential) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Count in the emergency fund")
                    Text("You’d still pay it with no income, so it’s one of the essentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var whenDueSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("When it’s due").font(.headline)
                step(1, bill.map { "The \($0.name) bill is marked paid from this stash, so it doesn’t count against that month’s budget." }
                    ?? "Pick this stash on the transaction when you spend it, and it’s paid from here instead of from that month’s budget.")
                step(2, draft.repeatsYearly
                    ? "Then it starts over for next \(draft.dueDate.formatted(.dateTime.month(.wide))), at \(Money.whole(StashMath.nextCycle(after: draft.dueDate, targetCents: draft.targetCents).monthlyCents)) a month. Anything left over carries forward."
                    : "Then it’s done. Anything left over goes back to Left to spend.")
            }
            .padding(.vertical, 6)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Brand.green)
                .frame(width: 28, height: 28)
                .background(Brand.greenPale, in: .circle)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An existing stash: what's in it, marking this month by hand, finishing a one-time stash,
    /// and deleting it.
    private func existingSection(_ stash: Stash, summary: StashSummary) -> some View {
        Section {
            LabeledContent("Stashed so far") {
                Text(Money.text(summary.balanceCents)).monospacedDigit()
            }
            if summary.thisMonthCents > 0 {
                LabeledContent("Counted this month") {
                    Text(Money.text(summary.thisMonthCents)).monospacedDigit()
                }
            }
            if !stash.countsAutomatically {
                if summary.thisMonthCents > 0 {
                    Button("Undo This Month’s Amount") {
                        StashScheduler.unmarkStashed(stash, in: context)
                    }
                    .foregroundStyle(Brand.expenseInk)
                } else if summary.status.isBehind {
                    Button("Mark Stashed") {
                        StashScheduler.markStashed(stash, in: context)
                    }
                    .foregroundStyle(.primary)
                }
            }
            if !stash.repeatsYearly, summary.status == .due || summary.status == .funded {
                Button("Finish This Stash") {
                    stash.isArchived = true
                    try? context.save()
                    dismiss()
                }
                .foregroundStyle(.primary)
            }
            Button("Delete Stash", role: .destructive) { confirmsDelete = true }
                .foregroundStyle(Brand.expenseInk)
        } footer: {
            if !stash.countsAutomatically, summary.status.isBehind {
                Text("Mark it once this month’s \(Money.whole(summary.monthlyCents)) is in \(accountName ?? "savings").")
            }
        }
    }

    // MARK: Text

    private var accountName: String? {
        accounts.first { $0.id == draft.accountID }?.displayName
    }

    /// "From your bills · State Farm, every March".
    private var origin: String {
        if let bill {
            let every = draft.repeatsYearly ? "every \(draft.dueDate.formatted(.dateTime.month(.wide)))" : "once"
            return "From your bills · \(bill.name), \(every)"
        }
        return draft.repeatsYearly ? "Every year" : "Just once"
    }

    private func summaryText(_ summary: StashSummary) -> String {
        let due = draft.dueDate.formatted(.dateTime.month(.abbreviated).year())
        if summary.status == .funded {
            return "You already have the \(Money.whole(draft.targetCents)) for \(due)."
        }
        guard draft.targetCents > 0 else { return "Type in how much it takes." }
        let months = summary.monthsLeft
        var text = "Covers \(Money.whole(draft.targetCents)) by \(due): \(months) month\(months == 1 ? "" : "s") at \(Money.whole(summary.monthlyCents))"
        text += summary.balanceCents > 0 ? ", on top of the \(Money.whole(summary.balanceCents)) already stashed." : "."
        return text
    }

    /// The months left to count, each with the amount stashed by its end.
    private func scheduleMonths(_ summary: StashSummary) -> [StashScheduleBars.Month] {
        let calendar = Calendar.current
        var month = MonthSpan(containing: .now, calendar: calendar)
        if summary.thisMonthCents > 0 || stash == nil || month.contains(preview.createdAt) {
            month = month.offset(by: 1, calendar: calendar)
        }
        var running = summary.balanceCents
        var result: [StashScheduleBars.Month] = []
        for _ in 0..<min(summary.monthsLeft, 12) {
            running += StashMath.amount(for: preview, month: month.start, balanceBefore: running, calendar: calendar)
            result.append(.init(start: month.start, stashedCents: running))
            month = month.offset(by: 1, calendar: calendar)
        }
        return result
    }

    // MARK: Saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let stash {
            draft = StashDraft(stash)
        } else {
            draft = initial
            if draft.accountID == nil {
                draft.accountID = accounts.first { $0.countsTowardEmergencyFund }?.id
            }
            if draft.name.isEmpty { focus = .name }
        }
        targetText = Money.field(draft.targetCents)
        openingText = Money.field(draft.openingCents)
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: Stash
        if let stash {
            target = stash
        } else {
            let count = (try? context.fetchCount(FetchDescriptor<Stash>())) ?? 0
            target = Stash(name: name, targetCents: draft.targetCents, dueDate: draft.dueDate, sortOrder: count)
            context.insert(target)
        }
        target.name = name
        target.symbol = draft.symbol
        target.color = draft.color
        target.targetCents = draft.targetCents
        target.dueDate = draft.dueDate
        target.repeatsYearly = draft.repeatsYearly
        target.openingCents = draft.openingCents
        target.accountID = draft.accountID
        target.billID = draft.billID
        target.countsAutomatically = draft.countsAutomatically
        target.isEssential = draft.isEssential
        try? context.save()
        // Switching to automatic counts anything owed.
        StashScheduler.run(in: context)
        dismiss()
    }

    private func delete() {
        guard let stash else { return }
        // What it paid for counts in those months' budgets again.
        for entry in StashScheduler.payments(from: stash, in: context) {
            entry.stashID = nil
            entry.stashCents = 0
        }
        for move in StashScheduler.moves(of: stash, in: context) {
            context.delete(move)
        }
        context.delete(stash)
        try? context.save()
        dismiss()
    }
}

/// A bar for each month until a stash is due, growing as it fills; the due month in green.
struct StashScheduleBars: View {
    struct Month: Hashable {
        var start: Date
        var stashedCents: Int
    }

    var months: [Month]
    var dueMonth: Date

    var body: some View {
        let most = max(months.map(\.stashedCents).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(months, id: \.start) { month in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(month.start == dueMonth ? Brand.green : CategoryColor.green.color.opacity(0.35))
                        .frame(height: 24 + 36 * CGFloat(month.stashedCents) / CGFloat(most))
                    Text(month.start.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Builds each month until \(dueMonth.formatted(.dateTime.month(.wide).year()))")
    }
}

#Preview {
    StashEditor(stash: nil, initial: StashDraft())
        .previewEnvironment()
}
