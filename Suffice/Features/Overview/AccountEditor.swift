import SwiftData
import SwiftUI

/// Add or change an account by hand: the bank, the account, its last four digits and today's
/// balance. Transactions filed to it afterward move the balance.
struct AccountEditor: View {
    let account: Account?
    var onSave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var institution = ""
    @State private var name = ""
    @State private var mask = ""
    @State private var kind: AccountKind = .checking
    @State private var balanceText = ""
    @State private var includeInBudget = true
    @State private var colorHex = 0x0E3E8C
    /// The Hearth color picker is open.
    @State private var pickingColor = false
    @State private var confirmsDelete = false
    @State private var pendingDelete = false
    /// The balance shown when the editor opened, to tell whether it was changed.
    @State private var loadedCents = 0
    /// Whether the balance was typed over (it's shown as currency, edited as a plain number).
    @State private var balanceEdited = false
    @State private var balanceAtFocus = ""
    @FocusState private var balanceFocused: Bool

    init(account: Account?, onSave: (() -> Void)? = nil) {
        self.account = account
        self.onSave = onSave
    }

    private var isValid: Bool {
        !institution.trimmingCharacters(in: .whitespaces).isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        InstitutionLogo(name: institution.isEmpty ? name : institution, colorHex: colorHex, isCard: kind == .credit, size: 48, domain: account?.institutionDomain)
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Bank", text: $institution)
                                .font(.title3.weight(.semibold))
                                .textInputAutocapitalization(.words)
                            TextField("Account name", text: $name)
                                .foregroundStyle(.secondary)
                                .textInputAutocapitalization(.words)
                        }
                    }
                    Button { pickingColor = true } label: {
                        HearthColorSwatchLabel(color: $colorHex.hearthAccountColor.wrappedValue)
                    }
                    .hearthColorPicker(
                        isPresented: $pickingColor,
                        title: accountTitle,
                        caption: "Account",
                        color: $colorHex.hearthAccountColor
                    )
                }

                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    LabeledContent("Last 4 digits") {
                        TextField("0000", text: $mask)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: mask) { _, value in
                                let digits = String(value.filter(\.isNumber).suffix(4))
                                if digits != value { mask = digits }
                            }
                    }
                    LabeledContent(kind == .credit ? "Balance owed" : "Balance today") {
                        TextField(Money.text(0), text: $balanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($balanceFocused)
                            .onChange(of: balanceFocused) { _, focused in
                                if focused {
                                    // Plain digits while typing…
                                    balanceAtFocus = Money.editable(balanceCents)
                                    balanceText = balanceAtFocus
                                } else {
                                    // …and currency again after.
                                    if balanceText != balanceAtFocus { balanceEdited = true }
                                    balanceText = Money.text(balanceCents)
                                }
                            }
                    }
                    Toggle("Include in budget", isOn: $includeInBudget)
                } footer: {
                    Text("Transactions you file to this account after today move its balance. Accounts left out of the budget don't count toward Total cash.")
                }

                if account != nil {
                    Section {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label("Remove Account", systemImage: "xmark")
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
            .navigationTitle(account == nil ? "New Account" : "Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .alert("Remove this account?", isPresented: $confirmsDelete) {
                Button("Remove Account", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if account?.source == .plaid {
                    Text("Its transactions stay in Activity. It comes back the next time its bank syncs; to stop that, disconnect the bank in Connected accounts, or turn off Include in budget instead.")
                } else {
                    Text("Its transactions stay in Activity.")
                }
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let account else { return }
                context.delete(account)
                try? context.save()
            }
        }
    }

    private func load() {
        guard let account else { return }
        institution = account.institution
        name = account.name
        mask = account.mask
        kind = account.kind
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        loadedCents = BudgetMath.balance(of: account.record, entries: entries.map(\.record))
        balanceText = Money.text(loadedCents)
        includeInBudget = account.includeInBudget
        colorHex = account.colorHex
    }

    /// The balance as it stands in the field: what was loaded until it's typed over.
    private var balanceCents: Int {
        let typing = balanceFocused && balanceText != balanceAtFocus
        guard account == nil || balanceEdited || typing else { return loadedCents }
        return Money.cents(from: balanceText) ?? 0
    }

    /// The account's name for the color picker: "Chase Checking", or what's typed so far.
    private var accountTitle: String {
        let bank = institution.trimmingCharacters(in: .whitespaces)
        let accountName = name.trimmingCharacters(in: .whitespaces)
        let title = [bank, accountName].filter { !$0.isEmpty }.joined(separator: " ")
        return title.isEmpty ? "New account" : title
    }

    private func save() {
        let cents = balanceCents
        let target: Account
        if let account {
            target = account
        } else {
            target = Account(institution: "", name: "", kind: kind, balanceCents: 0, sortOrder: (accounts.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        // A new balance resets the starting point for manual adjustments.
        if account == nil || cents != loadedCents {
            target.balanceCents = cents
            target.balanceDate = .now
        }
        target.institution = institution.trimmingCharacters(in: .whitespaces)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.mask = mask
        target.kind = kind
        target.includeInBudget = includeInBudget
        target.colorHex = colorHex
        try? context.save()
        dismiss()
        onSave?()
    }
}

#Preview {
    AccountEditor(account: nil)
        .previewEnvironment()
}
