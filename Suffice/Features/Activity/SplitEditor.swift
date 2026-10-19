import SwiftData
import SwiftUI

/// Split one charge across budgets, from the transaction sheet: parts, each with its budget (or
/// subcategory) and amount, that must add up to the charge before Done. The first part takes
/// "the rest" on its own until its amount is typed in, so splitting off one thing is a budget
/// and an amount. With a receipt, the on-device model can suggest the parts.
///
/// Done hands back the parts: two or more for a split, one to undo the split.
struct SplitEditor: View {
    let totalCents: Int
    var initialParts: [EntrySplit]
    var initialCategoryID: UUID?
    var receipt: Data?
    /// Opened from Split From This Receipt: suggest as soon as it opens.
    var suggestsOnAppear = false
    var save: ([EntrySplit]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var parts: [PartDraft] = []
    /// The first part follows what the others leave until someone types its amount.
    @State private var firstIsRest = false
    @State private var loaded = false
    @State private var suggesting = false
    @State private var suggestionError: String?
    @State private var suggested = false
    @FocusState private var focused: UUID?

    struct PartDraft: Identifiable, Equatable {
        var id = UUID()
        var categoryID: UUID?
        var text: String
        /// Its own tax tag; nil goes by the charge's.
        var taxTag: TaxTag?

        var cents: Int { Money.cents(from: text) ?? 0 }
    }

    private var assigned: Int { parts.reduce(0) { $0 + $1.cents } }
    private var remaining: Int { totalCents - assigned }
    private var filled: [PartDraft] { parts.filter { $0.cents > 0 } }
    private var missingBudget: Bool { filled.contains { $0.categoryID == nil } }
    private var canSave: Bool { remaining == 0 && !filled.isEmpty && !missingBudget }

    var body: some View {
        let lookup = Lookup(categories: categories)
        let choices = CategoryChoice.budgetsAndSubcategories(categories)

        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(statusTitle).fontWeight(.semibold)
                        Spacer()
                        Text("of \(Money.text(totalCents))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text(remaining == 0 ? Money.text(totalCents) : Money.text(abs(remaining)))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(remaining == 0 ? Brand.greenInk : (remaining > 0 ? CategoryColor.orange.ink : Brand.expenseInk))
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    SplitBar(
                        segments: filled.map { (color: lookup.category($0.categoryID)?.color.color ?? Color(.systemGray3), cents: $0.cents) },
                        remainingCents: max(remaining, 0)
                    )

                    HStack(spacing: 8) {
                        TintedCapsuleButton(title: "Split Evenly", systemImage: nil) { splitEvenly() }
                        if remaining != 0 && !parts.isEmpty {
                            TintedCapsuleButton(title: remaining > 0 ? "Rest to Last Part" : "Take Off Last Part", systemImage: nil) { fillLast() }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
                .animation(.snappy, value: remaining)
                .accessibilityElement(children: .contain)
            }

            if receipt != nil {
                Section {
                    Button { Task { await suggest() } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(Brand.green)
                                .frame(width: 30, height: 30)
                                .background(Brand.greenPale, in: .circle)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggested ? "Suggest Again" : "Suggest From Receipt")
                                    .foregroundStyle(ReceiptSplitter.isAvailable ? Brand.green : .secondary)
                                Text(suggesting ? "Reading the receipt…" : "Reads the items on your \(DeviceName.current)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if suggesting { ProgressView() }
                        }
                    }
                    .disabled(suggesting || !ReceiptSplitter.isAvailable)
                } footer: {
                    if let suggestionError {
                        Text(suggestionError).foregroundStyle(Brand.expenseInk)
                    } else if !ReceiptSplitter.isAvailable {
                        Text(OnDeviceModel.availability.message)
                    } else if suggested {
                        Text("Check each part: tax and savings are spread across them by size.")
                    }
                }
            }

            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                Section {
                    CategoryPicker(title: "Budget", selection: categoryBinding(part.id), choices: choices, noneTitle: "Choose")
                    LabeledContent(index == 0 && firstIsRest && parts.count > 1 ? "Amount · the rest" : "Amount") {
                        TextField(Money.text(0), text: textBinding(part.id))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($focused, equals: part.id)
                            .currencyEditing(textBinding(part.id), isFocused: focused == part.id)
                    }
                    // A part can carry its own tag: the gift card on a Costco run, for Business.
                    Picker("Tax", selection: taxBinding(part.id)) {
                        Text("Same as the charge").tag(TaxTag?.none)
                        ForEach(TaxTag.allCases) { tag in
                            Text(tag.name).tag(TaxTag?.some(tag))
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    HStack {
                        Text("Part \(index + 1)")
                        Spacer()
                        if parts.count > 1 {
                            Button("Remove", role: .destructive) { remove(part.id) }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.expenseInk)
                                .textCase(nil)
                                .accessibilityLabel("Remove part \(index + 1)")
                        }
                    }
                }
            }

            Section {
                Button { addPart() } label: {
                    Label("Add a Part", systemImage: "plus.circle.fill")
                        .foregroundStyle(Brand.green)
                }
            } footer: {
                Text(missingBudget
                     ? "Pick a budget for every part."
                     : "Each part counts toward its own budget. Activity and your bank still show one \(Money.text(totalCents)) charge. Remove parts down to one to undo the split.")
            }
        }
        .navigationTitle("Split \(Money.text(totalCents))")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SheetDoneButton { finish() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            load()
            if suggestsOnAppear { Task { await suggest() } }
        }
        .onChange(of: parts.dropFirst().map(\.text)) { keepRestCurrent() }
        .sensoryFeedback(.success, trigger: remaining == 0) { _, balanced in balanced }
    }

    private var statusTitle: String {
        if remaining == 0 { return "All assigned" }
        return remaining > 0 ? "Left to assign" : "Over by"
    }

    // MARK: Editing

    private func load() {
        if initialParts.count > 1 {
            parts = initialParts.map { PartDraft(id: $0.id, categoryID: $0.categoryID, text: Money.field($0.amountCents), taxTag: $0.taxTag) }
            firstIsRest = false
        } else {
            // Splitting starts from the charge as it's filed, plus an empty part to split off.
            parts = [
                PartDraft(categoryID: initialCategoryID, text: Money.field(totalCents)),
                PartDraft(categoryID: nil, text: ""),
            ]
            firstIsRest = true
        }
    }

    private func categoryBinding(_ id: UUID) -> Binding<UUID?> {
        Binding(
            get: { parts.first { $0.id == id }?.categoryID },
            set: { value in
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                parts[index].categoryID = value
            }
        )
    }

    private func taxBinding(_ id: UUID) -> Binding<TaxTag?> {
        Binding(
            get: { parts.first { $0.id == id }?.taxTag },
            set: { value in
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                parts[index].taxTag = value
            }
        )
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { parts.first { $0.id == id }?.text ?? "" },
            set: { value in
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                // Typing into the first part takes it off "the rest". (Formatting the field when
                // it gains or loses focus also writes here, even while focused, but never changes
                // the amount, so only a new amount counts.)
                if index == 0, focused == id, (Money.cents(from: value) ?? 0) != parts[0].cents { firstIsRest = false }
                parts[index].text = value
            }
        )
    }

    /// While the first part is "the rest", it's whatever the others leave.
    private func keepRestCurrent() {
        guard firstIsRest, parts.count > 1 else { return }
        let others = parts.dropFirst().reduce(0) { $0 + $1.cents }
        let rest = Money.field(max(totalCents - others, 0))
        if parts[0].text != rest { parts[0].text = rest }
    }

    private func addPart() {
        let left = max(remaining, 0)
        withAnimation(.snappy) {
            parts.append(PartDraft(categoryID: nil, text: firstIsRest ? "" : Money.field(left)))
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy) {
            // Removing "the rest" leaves the next part as typed, not as the new rest.
            if parts.first?.id == id { firstIsRest = false }
            parts.removeAll { $0.id == id }
            if parts.count == 1 { firstIsRest = false }
        }
        keepRestCurrent()
    }

    private func splitEvenly() {
        firstIsRest = false
        let shares = SplitMath.evenly(total: totalCents, count: parts.count)
        for index in parts.indices { parts[index].text = Money.field(shares[index]) }
    }

    private func fillLast() {
        firstIsRest = false
        guard let last = parts.indices.last else { return }
        parts[last].text = Money.field(max(parts[last].cents + remaining, 0))
    }

    private func suggest() async {
        guard let receipt, !suggesting else { return }
        suggesting = true
        suggestionError = nil
        defer { suggesting = false }
        do {
            let result = try await ReceiptSplitter.suggest(receipt: receipt, totalCents: totalCents, categories: categories)
            withAnimation(.snappy) {
                firstIsRest = false
                parts = result.map { PartDraft(id: $0.id, categoryID: $0.categoryID, text: Money.field($0.amountCents)) }
                if parts.count == 1 { parts.append(PartDraft(categoryID: nil, text: "")) }
            }
            suggested = true
        } catch {
            suggestionError = error.localizedDescription
        }
    }

    private func finish() {
        let result = filled.map { EntrySplit(id: $0.id, categoryID: $0.categoryID, amountCents: $0.cents, taxTag: $0.taxTag) }
        save(result)
        dismiss()
    }
}

/// A split's parts as one bar, each in its budget's color, with what's unassigned in gray.
struct SplitBar: View {
    var segments: [(color: Color, cents: Int)]
    var remainingCents: Int = 0

    private var pieces: [(Color, Int)] {
        var pieces: [(Color, Int)] = segments.filter { $0.cents > 0 }.map { ($0.color, $0.cents) }
        if remainingCents > 0 { pieces.append((Color(.systemGray5), remainingCents)) }
        return pieces
    }

    var body: some View {
        let pieces = self.pieces
        let total = max(pieces.reduce(0) { $0 + $1.1 }, 1)
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let width = max(proxy.size.width - spacing * CGFloat(max(pieces.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    Capsule()
                        .fill(piece.0)
                        .frame(width: max(width * CGFloat(piece.1) / CGFloat(total), 3))
                }
            }
        }
        .frame(height: 8)
        .background(Color(.systemGray6), in: .capsule)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}
