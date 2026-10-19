import SwiftData
import SwiftUI

/// Add or change a loan by hand: what it's for, what was borrowed, the rate, the term and the
/// first payment. The monthly payment and today's balance are worked out from those, and can be
/// typed over with the numbers from a statement.
struct LoanEditor: View {
    let loan: Loan?
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]

    @State private var name = ""
    @State private var lender = ""
    @State private var kind: LoanKind = .mortgage
    @State private var color: CategoryColor = LoanKind.mortgage.color
    @State private var originalText = ""
    @State private var rateText = ""
    @State private var termText = ""
    @State private var firstPayment = Date.now
    @State private var paymentText = ""
    @State private var escrowText = ""
    @State private var balanceText = ""
    @State private var isPaidOff = false
    /// Today's balance when the editor opened, to tell whether it was typed over.
    @State private var loadedBalance: Int?
    @State private var confirmsDelete = false
    @State private var pendingDelete = false
    /// Filled in once; coming back from the Type list shows the editor again.
    @State private var loaded = false
    @FocusState private var focus: Field?

    private enum Field { case name, lender, original, rate, term, payment, escrow, balance }

    init(loan: Loan?, onDelete: (() -> Void)? = nil) {
        self.loan = loan
        self.onDelete = onDelete
    }

    // MARK: What's typed

    private var originalCents: Int { Money.cents(from: originalText) ?? 0 }
    private var rate: Double { Self.number(rateText) }
    private var termMonths: Int { Int((Self.number(termText) * 12).rounded()) }

    /// A typed number, with a decimal point or comma: "6.25", "6,25".
    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }) ?? 0
    }
    private var calculatedPayment: Int { LoanMath.payment(principalCents: originalCents, annualRate: rate, months: termMonths) }
    private var paymentCents: Int { Money.cents(from: paymentText).flatMap { $0 > 0 ? $0 : nil } ?? calculatedPayment }
    private var estimatedBalance: Int {
        LoanMath.scheduledBalance(originalCents: originalCents, annualRate: rate, paymentCents: paymentCents, firstPaymentDate: firstPayment)
    }
    private var balanceCents: Int { Money.cents(from: balanceText) ?? estimatedBalance }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && originalCents > 0 && termMonths > 0 && paymentCents > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        WealthIcon(symbol: kind.symbol, color: color, size: 48)
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Name", text: $name)
                                .font(.title3.weight(.semibold))
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .name)
                            TextField("Lender", text: $lender)
                                .foregroundStyle(.secondary)
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .lender)
                        }
                    }
                    Picker("Type", selection: kindChoice) {
                        ForEach(LoanKind.allCases) { option in
                            Label(option.name, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Color") {
                    ColorChoiceGrid(selection: $color)
                }

                Section {
                    LabeledContent("Amount borrowed") {
                        amountField(Money.text(0), text: $originalText, field: .original)
                    }
                    LabeledContent("Interest rate") {
                        HStack(spacing: 2) {
                            TextField("0", text: $rateText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focus, equals: .rate)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Term") {
                        HStack(spacing: 4) {
                            TextField("30", text: $termText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focus, equals: .term)
                            Text("years").foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("First payment", selection: $firstPayment, displayedComponents: .date)
                } header: {
                    Text("Loan")
                } footer: {
                    Text("From your loan papers. Payments come due on the first payment’s day each month.")
                }

                Section {
                    LabeledContent("Monthly payment") {
                        amountField(Money.text(calculatedPayment), text: $paymentText, field: .payment)
                    }
                    if kind == .mortgage || kind == .homeEquity || !escrowText.isEmpty {
                        LabeledContent("Escrow") {
                            amountField(Money.text(0), text: $escrowText, field: .escrow)
                        }
                    }
                } header: {
                    Text("Payments")
                } footer: {
                    Text(kind == .mortgage
                         ? "Principal and interest only; leave it blank to use \(Money.text(calculatedPayment)). Escrow is the taxes and insurance collected with it."
                         : "Leave it blank to use \(Money.text(calculatedPayment)), worked out from the loan.")
                }

                Section {
                    LabeledContent("Owed today") {
                        amountField(Money.text(estimatedBalance), text: $balanceText, field: .balance)
                    }
                    if loan != nil {
                        Toggle("Paid off", isOn: $isPaidOff)
                    }
                } header: {
                    Text("Balance")
                } footer: {
                    Text("Leave it blank to use the schedule’s \(Money.text(estimatedBalance)). Type in your statement’s balance whenever it differs; each payment due after that brings it down.")
                }

                if loan != nil {
                    Section {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label("Delete Loan", systemImage: "trash")
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
            .navigationTitle(loan == nil ? "New Loan" : "Loan")
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
            .alert("Delete this loan?", isPresented: $confirmsDelete) {
                Button("Delete Loan", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It comes off Net Worth and Debts. To keep it for the record, turn on Paid off instead.")
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let loan else { return }
                context.delete(loan)
                try? context.save()
                onDelete?()
            }
        }
    }

    /// Picking a type brings its name, color and usual term, unless they were changed.
    private var kindChoice: Binding<LoanKind> {
        Binding(
            get: { kind },
            set: { new in
                let old = kind
                if name.isEmpty || name == old.name { name = new.name }
                if color == old.color { color = new.color }
                if termText.isEmpty || termText == years(old.typicalTermMonths) { termText = years(new.typicalTermMonths) }
                kind = new
            }
        )
    }

    private func amountField(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focus, equals: field)
            .currencyEditing(text, isFocused: focus == field)
    }

    private func years(_ months: Int) -> String {
        let value = Double(months) / 12
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let loan else {
            name = kind.name
            termText = years(kind.typicalTermMonths)
            return
        }
        name = loan.name
        lender = loan.lender
        kind = loan.kind
        color = loan.color
        originalText = Money.field(loan.originalCents)
        rateText = loan.annualRate.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
        termText = years(loan.termMonths)
        firstPayment = loan.firstPaymentDate
        paymentText = Money.field(loan.paymentCents)
        escrowText = Money.field(loan.escrowCents)
        // What the schedule says is owed even when it's marked paid off, so saving a paid-off
        // loan doesn't take the blank field as a new balance.
        var record = loan.record
        record.isPaidOff = false
        let balance = LoanMath.currentBalance(record)
        loadedBalance = balance
        balanceText = Money.field(balance)
        isPaidOff = loan.isPaidOff
    }

    private func save() {
        let target: Loan
        if let loan {
            target = loan
        } else {
            target = Loan(name: "", kind: kind, originalCents: 0, annualRate: 0, termMonths: 0, firstPaymentDate: firstPayment, paymentCents: 0, balanceCents: 0, sortOrder: (loans.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        let balance = balanceCents
        // A balance typed over (or a new loan) starts the count again from today.
        if loan == nil || balance != loadedBalance {
            target.balanceCents = balance
            target.balanceDate = .now
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.lender = lender.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.color = color
        target.originalCents = originalCents
        target.annualRate = rate
        target.termMonths = termMonths
        target.firstPaymentDate = firstPayment
        target.paymentCents = paymentCents
        target.escrowCents = Money.cents(from: escrowText) ?? 0
        target.isPaidOff = isPaidOff
        try? context.save()
        dismiss()
    }
}

#Preview {
    LoanEditor(loan: nil)
        .previewEnvironment()
}
