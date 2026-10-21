import MapKit
import SwiftData
import SwiftUI
import UIKit

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
    @Query(sort: \Stash.sortOrder) private var allStashes: [Stash]
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
    @State private var confirmsRemoveReceipt = false
    @State private var showsTaxTags = false
    @State private var alwaysTag = false
    @State private var earlierCount = 0
    @State private var asksAboutEarlier = false
    @State private var purchases = HearthPurchases.shared
    /// Split From This Receipt needs Suffice Plus or Hearth+.
    @State private var showsSplitPaywall = false
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

                if draft.kind == .expense && draft.isSplit {
                    splitSection(lookup: lookup)
                } else if draft.kind == .expense {
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

                        NavigationLink {
                            splitEditor(suggests: false)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Split Across Budgets").foregroundStyle(.primary)
                                    Text("One charge, several budgets")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .disabled(draft.amountCents <= 0)

                        Toggle(isOn: $alwaysUse) {
                            Text("Always use this category for \(draft.payee.isEmpty ? "this payee" : draft.payee)")
                        }
                        .disabled(budget == nil || draft.payee.trimmingCharacters(in: .whitespaces).isEmpty)
                        .onChange(of: alwaysUse) { _, value in
                            draft.alwaysUseCategory = value
                        }
                    }
                }

                if draft.kind == .expense {
                    taxSection
                    if draft.taxTag.isTagged, draft.receipt == nil {
                        keepReceiptCard
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
                    // Spending a stash was saved for (Christmas): it's paid from the stash, not
                    // from this month's budget.
                    // A used one-time stash is archived; one this transaction drew from still shows.
                    let stashes = allStashes.filter { !$0.isArchived || $0.id == draft.stashID }
                    if draft.kind == .expense, !stashes.isEmpty {
                        Picker("Paid from", selection: $draft.stashID) {
                            Text("This month’s budget").tag(UUID?.none)
                            ForEach(stashes) { stash in
                                Text("Stash: \(stash.name)").tag(UUID?.some(stash.id))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    TextField("Note", text: $draft.note, axis: .vertical)
                        .focused($focus, equals: .note)
                }

                ReceiptSection(receipt: $draft.receipt, isPreparing: preparingReceipt) { receiptRequest = $0 }

                if let entry, entry.receiptSourceRaw == "email", draft.receipt != nil, draft.receipt == entry.receiptData {
                    emailReceiptSection(entry)
                }

                if draft.kind == .expense, draft.receipt != nil, !draft.isSplit, draft.amountCents > 0, ReceiptSplitter.isAvailable {
                    Section {
                        if purchases.isUnlocked {
                            NavigationLink {
                                splitEditor(suggests: true)
                            } label: {
                                splitFromReceiptLabel
                            }
                        } else {
                            Button { showsSplitPaywall = true } label: {
                                splitFromReceiptLabel
                            }
                        }
                    }
                }

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
            .hearthPaywall(isPresented: $showsSplitPaywall, feature: ReceiptSplitter.paywallFeature)
            .scrollDismissesKeyboard(.interactively)
            // Presented from here, outside the rows, so they stay open.
            .receiptPresenter(receipt: $draft.receipt, request: $receiptRequest, isPreparing: $preparingReceipt)
            .alert("Remove this receipt?", isPresented: $confirmsRemoveReceipt) {
                // Taken off when you save; it won't be attached again.
                Button("Remove", role: .destructive) { draft.receipt = nil }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The email stays in your mailbox.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton { save() }
                        .disabled(!draft.isValid)
                }
            }
            .alert("Tag \(earlierCount) earlier \(draft.payee) transaction\(earlierCount == 1 ? "" : "s") from this year too?", isPresented: $asksAboutEarlier) {
                Button("Tag Them") { draft.tagsEarlier = true }
                Button("Not Now", role: .cancel) { draft.tagsEarlier = false }
            } message: {
                Text("They’d be tagged \(draft.taxTag.name), like this one.")
            }
            .onChange(of: draft.categoryID) { previewTaxTag() }
            .onChange(of: draft.payee) { previewTaxTag() }
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

    // MARK: Tax

    /// The Tax row, which opens into the tags like the category list, and "Always tag <payee>".
    private var taxSection: some View {
        Section {
            Button {
                withAnimation(.snappy) { showsTaxTags.toggle() }
            } label: {
                HStack {
                    Text("Tax").foregroundStyle(.primary)
                    Spacer()
                    TaxTagPill(tag: draft.taxTag)
                }
            }
            .accessibilityValue(draft.taxTag.name)
            .accessibilityHint(showsTaxTags ? "Hides the tax tags" : "Shows the tax tags")

            if showsTaxTags {
                ForEach(TaxTag.allCases) { tag in
                    Button {
                        draft.taxTag = tag
                        draft.taxTagChosen = true
                        // No tag leaves any rule as it is; another tag with the switch on
                        // changes the rule to it.
                        if !tag.isTagged {
                            draft.alwaysTagPayee = nil
                        } else if alwaysTag {
                            draft.alwaysTagPayee = true
                        }
                        withAnimation(.snappy) { showsTaxTags = false }
                    } label: {
                        HStack(spacing: 12) {
                            TaxTagIcon(tag: tag, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tag.name).foregroundStyle(.primary)
                                Text(tag.hint)
                                    .font(.caption)
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Spacer()
                            if tag == draft.taxTag {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Brand.green)
                            }
                        }
                        .padding(.leading, 16)
                    }
                    .listRowBackground(tag == draft.taxTag ? Brand.green.opacity(0.06) : nil)
                    .accessibilityAddTraits(tag == draft.taxTag ? .isSelected : [])
                }
            }

            Toggle(isOn: Binding(get: { alwaysTag && draft.taxTag.isTagged }, set: setAlwaysTag)) {
                Text(alwaysTagTitle)
            }
            .disabled(!draft.taxTag.isTagged || draft.payee.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text("Tags don’t change budgets. They collect what you might need at tax time; ask your tax preparer what you can deduct.")
        }
    }

    private var alwaysTagTitle: String {
        let payee = draft.payee.trimmingCharacters(in: .whitespaces).isEmpty ? "this payee" : draft.payee
        return draft.taxTag.isTagged ? "Always tag \(payee) as \(draft.taxTag.name)" : "Always tag \(payee)"
    }

    /// Flipping "Always tag" on offers to tag this year's earlier transactions from the payee.
    private func setAlwaysTag(_ on: Bool) {
        alwaysTag = on
        draft.alwaysTagPayee = on
        draft.tagsEarlier = false
        guard on else { return }
        earlierCount = Ledger.untaggedThisYear(payee: draft.payee, in: context).filter { $0.id != entry?.id }.count
        if earlierCount > 0 { asksAboutEarlier = true }
    }

    /// "From your email": where an attached receipt came from, a way back to the message, and
    /// Remove Receipt (it won't be attached again).
    private func emailReceiptSection(_ entry: LedgerEntry) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From your email")
                    Text("Suffice found this receipt and attached it")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.secondary)
            }
            if let link = URL(string: entry.receiptLink), link.scheme == "https" {
                Link(destination: link) {
                    Label("Open the Email", systemImage: "arrow.up.right.square")
                        .foregroundStyle(.primary)
                }
            }
            Button("Remove Receipt", role: .destructive) {
                confirmsRemoveReceipt = true
            }
        }
    }

    /// "Keep the receipt": a tagged transaction without one.
    private var keepReceiptCard: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "receipt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CategoryColor.orange.ink)
                    .frame(width: 36, height: 36)
                    .background(CategoryColor.orange.tint, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the receipt").font(.headline)
                    Text("\(draft.taxTag.name) costs are easier to claim with a receipt. It stays with this transaction.")
                        .font(.footnote)
                        .foregroundStyle(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                TintedCapsuleButton(title: "Scan", systemImage: nil) {
                    receiptRequest = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .library
                }
                .accessibilityLabel("Scan the receipt")
            }
            .padding(.vertical, 4)
        }
    }

    /// A new (or untagged) transaction shows the tag it'll get from its payee's rule or budget,
    /// until someone picks one.
    private func previewTaxTag() {
        guard draft.kind == .expense, !draft.taxTagChosen, entry.map({ !$0.taxTag.isTagged }) ?? true else { return }
        draft.taxTag = Ledger.stampedTag(own: .untagged, payee: draft.payee, categoryID: draft.categoryID, kind: draft.kind, in: context)
        // The payee's rule shows as on when it's where the tag came from.
        if let rule = Ledger.rule(for: draft.payee, in: context) {
            alwaysTag = rule.taxTag.isTagged && rule.taxTag == draft.taxTag
        } else {
            alwaysTag = false
        }
    }

    // MARK: Split

    /// A split charge: a bar of its parts, each part with its budget and amount, and Edit Split.
    private func splitSection(lookup: Lookup) -> some View {
        let parts = draft.splits
        let remaining = SplitMath.remaining(total: draft.amountCents, parts: parts)
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Split across \(parts.count) budgets")
                    Spacer()
                    if remaining == 0 {
                        Label("All assigned", systemImage: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.greenInk)
                    } else {
                        // The amount changed after splitting; saving puts the difference on
                        // the last part.
                        Text(remaining > 0 ? "\(Money.text(remaining)) to the last part" : "\(Money.text(-remaining)) off the last part")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(CategoryColor.orange.ink)
                    }
                }
                SplitBar(segments: parts.map { (color: lookup.category($0.categoryID)?.color.color ?? Color(.systemGray3), cents: $0.amountCents) })
            }
            .padding(.vertical, 4)

            ForEach(parts) { part in
                let category = lookup.category(part.categoryID)
                HStack(spacing: 12) {
                    if let category {
                        CategoryIcon(category, size: 32)
                    } else {
                        Image(systemName: "questionmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lookup.budget(for: part.categoryID)?.name ?? "No budget")
                        if let sub = lookup.subcategory(for: part.categoryID) {
                            Text(sub.name)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Money.text(part.amountCents))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }

            NavigationLink {
                splitEditor(suggests: false)
            } label: {
                Text("Edit Split").foregroundStyle(.primary)
            }
        }
    }

    private var splitFromReceiptLabel: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Split From This Receipt").foregroundStyle(.primary)
                Text("Reads the items on your \(DeviceName.current) and suggests budgets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "sparkles")
                .foregroundStyle(.primary)
        }
    }

    /// The split editor for this charge. Done with two or more parts splits it; with one, it's
    /// filed whole to that part's budget again.
    private func splitEditor(suggests: Bool) -> some View {
        SplitEditor(
            totalCents: draft.amountCents,
            initialParts: draft.splits,
            initialCategoryID: draft.categoryID,
            receipt: draft.receipt,
            suggestsOnAppear: suggests
        ) { parts in
            if parts.count > 1 {
                draft.splits = parts
                draft.categoryID = SplitMath.primaryCategory(parts)
                // A split charge has no one category to always use; leave any rule alone.
                draft.alwaysUseCategory = nil
            } else {
                draft.splits = []
                if let only = parts.first { draft.categoryID = only.categoryID }
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
                            previewTaxTag()
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
            let rule = Ledger.rule(for: entry.payee, in: context)
            alwaysUse = rule.map { rule in
                let lookup = Lookup(categories: categories)
                return rule.categoryID != nil && lookup.budget(for: rule.categoryID)?.id == lookup.budget(for: entry.categoryID)?.id
            } ?? false
            alwaysTag = rule.map { $0.taxTag.isTagged && $0.taxTag == entry.taxTag } ?? false
        } else {
            draft = initial
            if draft.memberID == nil, let id = UUID(uuidString: currentMember), members.contains(where: { $0.id == id }) {
                draft.memberID = id
            }
            focus = draft.payee.isEmpty ? .payee : .amount
        }
        amountText = focus == .amount ? Money.editable(draft.amountCents) : currencyText(draft.amountCents)
        // The rule toggles only write when someone flips them.
        draft.alwaysUseCategory = nil
        draft.alwaysTagPayee = nil
        previewTaxTag()
    }

    /// A payee with a rule fills in its category.
    private func applyRule() {
        guard entry == nil, draft.kind == .expense, draft.categoryID == nil,
              let category = Ledger.ruleCategory(for: draft.payee, in: context) else { return }
        draft.categoryID = category
        alwaysUse = true
        draft.alwaysUseCategory = nil
        previewTaxTag()
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
