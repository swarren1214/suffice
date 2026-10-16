import MapKit
import SwiftData
import SwiftUI

/// The transaction sheet from the designs: merchant, big amount, who and which account, then
/// the category pill that opens into a list, the subcategory, the "Always use this category"
/// rule, and the map when the purchase has a place. The same sheet adds a new transaction.
struct TransactionSheet: View {
    /// Nil to create a new transaction from `initial`.
    let entry: LedgerEntry?
    var initial: EntryDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""

    @State private var draft = EntryDraft()
    @State private var amountText = ""
    @State private var loaded = false
    @State private var showsCategories = false
    @State private var alwaysUse = false
    @State private var confirmsDelete = false
    @State private var pendingDelete = false
    @State private var receiptRequest: ReceiptRequest?
    @State private var preparingReceipt = false
    @FocusState private var focus: Field?

    private enum Field { case payee, amount, note }

    init(entry: LedgerEntry?, initial: EntryDraft = EntryDraft()) {
        self.entry = entry
        self.initial = initial
    }

    private var budgets: [BudgetCategory] {
        categories.filter { $0.parentID == nil && !$0.isArchived }
    }

    var body: some View {
        let lookup = Lookup(categories: categories, members: members, accounts: accounts)
        let budget = lookup.budget(for: draft.categoryID)
        let subcategories = budget.map { parent in categories.filter { $0.parentID == parent.id && !$0.isArchived } } ?? []

        NavigationStack {
            Form {
                header(lookup: lookup)

                if draft.kind == .expense {
                    Section {
                        Button {
                            withAnimation(.snappy) { showsCategories.toggle() }
                        } label: {
                            HStack {
                                Text("Category").foregroundStyle(.primary)
                                Spacer()
                                CategoryPill(name: budget?.name ?? "Choose", color: budget?.color, symbol: budget?.symbol)
                            }
                        }
                        .accessibilityValue(budget?.name ?? "None")
                        .accessibilityHint(showsCategories ? "Hides the categories" : "Shows the categories")

                        if showsCategories {
                            ForEach(budgets) { option in
                                Button {
                                    draft.categoryID = option.id
                                    withAnimation(.snappy) { showsCategories = false }
                                } label: {
                                    HStack(spacing: 12) {
                                        CategoryIcon(option)
                                        Text(option.name).foregroundStyle(.primary)
                                        Spacer()
                                        if option.id == budget?.id {
                                            Image(systemName: "checkmark")
                                                .fontWeight(.semibold)
                                                .foregroundStyle(Brand.green)
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                                .listRowBackground(option.id == budget?.id ? Brand.green.opacity(0.06) : nil)
                                .accessibilityAddTraits(option.id == budget?.id ? .isSelected : [])
                            }
                        }

                        CategoryPicker(
                            title: "Subcategory",
                            selection: subcategoryBinding(budget: budget),
                            choices: subcategories.map { CategoryChoice($0) }
                        )
                        .disabled(subcategories.isEmpty)

                        Toggle(isOn: $alwaysUse) {
                            Text("Always use this category for \(draft.payee.isEmpty ? "this payee" : draft.payee)")
                        }
                        .disabled(budget == nil || draft.payee.trimmingCharacters(in: .whitespaces).isEmpty)
                        .onChange(of: alwaysUse) { _, value in
                            draft.alwaysUseCategory = value
                        }
                    }
                }

                Section {
                    if entry == nil {
                        Picker("Type", selection: $draft.kind) {
                            ForEach(EntryKind.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if !members.isEmpty {
                        Picker("Who", selection: $draft.memberID) {
                            Text("No one").tag(UUID?.none)
                            ForEach(members) { member in
                                Text(member.name).tag(UUID?.some(member.id))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    Picker("Account", selection: $draft.accountID) {
                        Text("None").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.displayName).tag(UUID?.some(account.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    TextField("Note", text: $draft.note, axis: .vertical)
                        .focused($focus, equals: .note)
                }

                ReceiptSection(receipt: $draft.receipt, isPreparing: preparingReceipt) { receiptRequest = $0 }

                if let entry, let latitude = entry.latitude, let longitude = entry.longitude {
                    Section {
                        PlaceMap(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), name: entry.placeAddress ?? entry.placeName, color: MerchantColor.color(for: entry.payee))
                            .frame(height: 160)
                            .listRowInsets(EdgeInsets())
                    }
                }

                if entry != nil {
                    Section {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label("Delete Transaction", systemImage: "trash")
                                .fontWeight(.semibold)
                                .foregroundStyle(Brand.expenseInk)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 40)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .tint(Brand.expenseInk)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle(entry == nil ? "New \(draft.kind.name)" : "Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            // Presented from here, outside the rows, so they stay open.
            .receiptPresenter(receipt: $draft.receipt, request: $receiptRequest, isPreparing: $preparingReceipt)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton { save() }
                        .disabled(!draft.isValid)
                }
            }
            .alert("Delete this transaction?", isPresented: $confirmsDelete) {
                Button("Delete Transaction", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: load)
            .task { await locate() }
            .onChange(of: focus) { old, new in
                // The amount reads as currency, and turns into plain digits while it's typed.
                if new == .amount {
                    amountText = Money.editable(draft.amountCents)
                } else if old == .amount {
                    amountText = currencyText(draft.amountCents)
                }
            }
            .onDisappear {
                guard pendingDelete, let entry else { return }
                Ledger.delete(entry, in: context)
            }
        }
    }

    /// Logo on the left; merchant, amount, and the date · who · account line beside it.
    private func header(lookup: Lookup) -> some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                MerchantAvatar(name: draft.payee.isEmpty ? "?" : draft.payee, isIncome: draft.kind == .income, size: 76, logoURL: entry?.logoURL)
                VStack(alignment: .leading, spacing: 2) {
                    TextField(draft.kind == .income ? "From" : "Merchant", text: $draft.payee)
                        .font(.title3.bold())
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .payee)
                        .submitLabel(.next)
                        .onSubmit {
                            applyRule()
                            focus = .amount
                        }
                    TextField(Money.text(0), text: $amountText)
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .amount)
                        .foregroundStyle(draft.kind == .income ? Brand.green : .primary)
                        .minimumScaleFactor(0.6)
                        .onChange(of: amountText) { _, value in
                            draft.amountCents = Money.cents(from: value) ?? 0
                        }
                        .accessibilityLabel("Amount")
                    Text(metaLine(lookup: lookup))
                        .font(.footnote)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    /// "$5.40", or empty for nothing yet so the placeholder shows.
    private func currencyText(_ cents: Int) -> String {
        cents == 0 ? "" : Money.text(cents)
    }

    /// Bank transactions with a street address but no coordinates: find the spot once with
    /// MapKit and keep it, so the map shows from then on.
    private func locate() async {
        guard let entry, entry.latitude == nil,
              let address = entry.placeAddress, !address.isEmpty,
              let request = MKGeocodingRequest(addressString: address),
              let location = try? await request.mapItems.first?.location else { return }
        entry.latitude = location.coordinate.latitude
        entry.longitude = location.coordinate.longitude
        try? context.save()
    }

    private func metaLine(lookup: Lookup) -> String {
        var parts = [draft.date.formatted(date: .abbreviated, time: .omitted)]
        if let member = lookup.member(draft.memberID) { parts.append(member.name) }
        if let account = lookup.account(draft.accountID) { parts.append(account.displayName) }
        return parts.joined(separator: " · ")
    }

    /// The subcategory menu: picking one files the transaction there; None files it under the budget.
    private func subcategoryBinding(budget: BudgetCategory?) -> Binding<UUID?> {
        Binding(
            get: {
                guard let id = draft.categoryID, id != budget?.id else { return nil }
                return id
            },
            set: { newValue in
                draft.categoryID = newValue ?? budget?.id
            }
        )
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let entry {
            draft = EntryDraft(entry)
            alwaysUse = Ledger.rule(for: entry.payee, in: context).map { rule in
                let lookup = Lookup(categories: categories)
                return lookup.budget(for: rule.categoryID)?.id == lookup.budget(for: entry.categoryID)?.id
            } ?? false
        } else {
            draft = initial
            if draft.memberID == nil, let id = UUID(uuidString: currentMember), members.contains(where: { $0.id == id }) {
                draft.memberID = id
            }
            focus = draft.payee.isEmpty ? .payee : .amount
        }
        amountText = focus == .amount ? Money.editable(draft.amountCents) : currencyText(draft.amountCents)
        // The rule toggle only writes when someone flips it.
        draft.alwaysUseCategory = nil
    }

    /// A payee with a rule fills in its category.
    private func applyRule() {
        guard entry == nil, draft.kind == .expense, draft.categoryID == nil,
              let category = Ledger.ruleCategory(for: draft.payee, in: context) else { return }
        draft.categoryID = category
        alwaysUse = true
        draft.alwaysUseCategory = nil
    }

    private func save() {
        applyRule()
        if let entry {
            Ledger.update(entry, with: draft, in: context)
        } else {
            Ledger.add(draft, in: context)
        }
        dismiss()
    }
}

/// The purchase location, drawn with MapKit.
private struct PlaceMap: View {
    var coordinate: CLLocationCoordinate2D
    var name: String?
    var color: Color

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
            Annotation(name ?? "", coordinate: coordinate) {
                Circle()
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(radius: 4, y: 2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let name {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .glassEffect(.regular, in: .capsule)
                    .padding(10)
            }
        }
        .accessibilityLabel("Map showing \(name ?? "where this happened")")
    }
}

#Preview {
    TransactionSheet(entry: nil)
        .previewEnvironment()
}
