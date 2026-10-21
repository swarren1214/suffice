import Charts
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A bill, from Bills: Pay at the place it's paid, the latest statement with its charges, the
/// last six bills, the details, and ways to add a bill (scan a paper one, or pick a PDF).
/// Edit opens the bill editor.
struct BillSheet: View {
    let bill: Bill

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var allStatements: [BillStatement]
    @Query(filter: #Predicate<LedgerEntry> { $0.billID != nil }) private var payments: [LedgerEntry]
    @State private var editing = false
    @State private var viewing: BillStatement?
    @State private var reviewing: BillStatement?
    @State private var importing: IncomingDocument?
    @State private var picksFile = false
    @State private var scanRequest: ReceiptRequest?
    @State private var scanned: Data?
    @State private var preparingScan = false
    @State private var importSource: StatementSource = .shared
    @State private var deleting = false

    private var statements: [BillStatement] {
        allStatements.filter { $0.billID == bill.id }.sorted { $0.dueDate > $1.dueDate }
    }

    var body: some View {
        let record = bill.record
        let records = statements.map(\.record)
        let next = BudgetMath.nextDue(of: record, onOrAfter: Calendar.current.startOfDay(for: .now))
        let paymentRecords = payments.map(\.record)
        let nextIsPaid = next.map { BudgetMath.payment(for: record, dueOn: $0, payments: paymentRecords) != nil } ?? false
        let amount = next.map { StatementMath.amount(for: record, dueOn: $0, statements: records) } ?? bill.amountCents

        NavigationStack {
            Form {
                header(amount: amount, next: next, isPaid: nextIsPaid)

                if let link = bill.payLink {
                    Section {
                        Button {
                            openURL(link)
                        } label: {
                            Label("Pay at \(bill.payHost ?? "the website")", systemImage: "arrow.up.right")
                                .labelStyle(TrailingIconLabelStyle())
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 50)
                                .background(Brand.green, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityHint("Opens \(bill.payHost ?? "the website") to pay")
                    } footer: {
                        Text(bill.isAutopay
                             ? "It’s on autopay there. When the payment leaves your bank, this bill marks itself paid."
                             : "Opens their app if it’s installed. When the payment leaves your bank, this bill marks itself paid.")
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }

                if let latest = statements.first {
                    latestSection(latest, previous: statements.dropFirst().first)
                }

                if statements.count > 1 {
                    historySection(records)
                }

                Section {
                    Button {
                        editing = true
                    } label: {
                        LabeledContent("Pay at") {
                            Text(bill.payHost ?? "Add where it’s paid")
                                .foregroundStyle(bill.payHost == nil ? Color.primary : .secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("Amount", value: bill.isVariable || !statements.isEmpty ? "From each bill" : bill.amountLabel)
                    LabeledContent("Due", value: BudgetMath.scheduleText(record))
                    if let category = categories.first(where: { $0.id == bill.categoryID }) {
                        LabeledContent("Category") {
                            CategoryPill(name: category.name, color: category.color, symbol: category.symbol)
                        }
                    }
                    if bill.isAutopay {
                        LabeledContent("Autopay", value: "On")
                    }
                }

                Section {
                    Button {
                        scanRequest = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .library
                    } label: {
                        Label("Scan a Paper Bill", systemImage: "doc.viewfinder")
                            .foregroundStyle(.primary)
                    }
                    Button {
                        picksFile = true
                    } label: {
                        Label("Add a Bill PDF", systemImage: "doc.badge.plus")
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("Suffice reads the amount, due date and charges on your \(DeviceName.current). You can also share a bill to Suffice from Mail or Files, and with email connected new bills come in on their own.")
                }
                .disabled(!DocumentReader.isAvailable)
            }
            .navigationTitle("Bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .tint(.primary)
                }
            }
            .refreshable { await HouseholdSync.shared.syncNow() }
            .receiptPresenter(receipt: $scanned, request: $scanRequest, isPreparing: $preparingScan)
            .overlay {
                if preparingScan {
                    ProgressView("Getting the scan ready…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 18))
                }
            }
            .onChange(of: scanned) { _, data in
                guard let data else { return }
                scanned = nil
                importSource = .scanned
                importing = IncomingDocument(data: data, type: "jpeg", fileName: "Scanned bill.jpg")
            }
            .fileImporter(isPresented: $picksFile, allowedContentTypes: [.pdf, .image]) { result in
                if case .success(let url) = result, let document = IncomingDocument.load(url) {
                    importSource = .shared
                    importing = document
                }
            }
            .sheet(isPresented: $editing, onDismiss: { if deleting { dismiss() } }) {
                BillEditor(bill: bill, onDelete: { deleting = true })
            }
            .onDisappear {
                // Deleted from Edit: gone once nothing shows it.
                guard deleting else { return }
                context.delete(bill)
                try? context.save()
            }
            .sheet(item: $viewing) { statement in
                StatementDocumentView(statement: statement)
            }
            .sheet(item: $reviewing) { statement in
                BillReadSheet(statement: statement)
            }
            .sheet(item: $importing) { document in
                BillImportSheet(document: document, source: importSource, billID: bill.id)
            }
        }
    }

    private func header(amount: Int, next: Date?, isPaid: Bool) -> some View {
        Section {
            HStack(spacing: 16) {
                Text(bill.initial)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(bill.color.ink, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.name)
                        .font(.title3.bold())
                    Text(Money.text(amount))
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    if let next {
                        Text(isPaid ? "Paid · due \(next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" : "Due \(next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isPaid ? Brand.greenInk : CategoryColor.orange.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            .accessibilityElement(children: .combine)
        }
    }

    /// The latest statement: its month, period and where it came from, its charges, and how it
    /// compares with the one before.
    private func latestSection(_ statement: BillStatement, previous: BillStatement?) -> some View {
        Section {
            ForEach(statement.charges) { charge in
                LabeledContent(charge.name) {
                    Text(Money.text(charge.amountCents)).monospacedDigit()
                }
            }
            LabeledContent {
                Text(Money.text(statement.amountCents))
                    .fontWeight(.bold)
                    .monospacedDigit()
            } label: {
                Text("Amount due").fontWeight(.semibold)
            }
            HStack(spacing: 8) {
                if statement.documentData != nil {
                    TintedCapsuleButton(title: "View Bill", systemImage: nil) { viewing = statement }
                }
                TintedCapsuleButton(title: statement.isReviewed ? "Check It" : "Review", systemImage: nil) { reviewing = statement }
                Spacer(minLength: 0)
                if let previous {
                    let change = statement.amountCents - previous.amountCents
                    if change != 0 {
                        Text("\(Money.whole(abs(change))) \(change > 0 ? "more" : "less") than \(previous.dueDate.formatted(.dateTime.month(.wide)))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(change > 0 ? CategoryColor.yellow.ink : CategoryColor.green.ink)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("\(statement.dueDate.formatted(.dateTime.month(.wide))) bill")
        } footer: {
            Text(statementLine(statement))
        }
    }

    private func statementLine(_ statement: BillStatement) -> String {
        var parts: [String] = []
        if let start = statement.periodStart, let end = statement.periodEnd {
            parts.append("\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
        }
        parts.append(statement.source.label.prefix(1).uppercased() + statement.source.label.dropFirst())
        return parts.joined(separator: " · ")
    }

    /// The last six bills as bars, newest in green, with their average.
    private func historySection(_ records: [StatementRecord]) -> some View {
        let history = StatementMath.history(bill.id, statements: records).reversed().map { $0 }
        let latest = history.last?.id
        return Section {
            Chart(history, id: \.id) { statement in
                BarMark(
                    x: .value("Month", statement.dueDate, unit: .month),
                    y: .value("Amount", Double(statement.amountCents) / 100)
                )
                .foregroundStyle(statement.id == latest ? Brand.green : CategoryColor.green.color.opacity(0.4))
                .cornerRadius(6)
                .annotation(position: .top) {
                    Text(Money.whole(statement.amountCents))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 150)
            .padding(.vertical, 6)
            .accessibilityLabel(history.map { "\($0.dueDate.formatted(.dateTime.month(.wide))) \(Money.whole($0.amountCents))" }.joined(separator: ", "))
        } header: {
            HStack {
                Text("Last \(history.count) bills")
                Spacer()
                if let average = StatementMath.average(history) {
                    Text("Average \(Money.text(average))")
                        .textCase(nil)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// A label with its icon after the title ("Pay at xpressbillpay.com ↗").
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Reading a bill

/// A new bill as Suffice read it: which bill it's for, the amount due, the due date and period,
/// its charges (and whether they add up), whether its amount is the one for that due date, and
/// whether to keep the PDF. Done marks it looked over.
struct BillReadSheet: View {
    let statement: BillStatement

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Bill> { $0.isActive == true }, sort: \Bill.name) private var bills: [Bill]
    @State private var billID: UUID?
    @State private var amountText = ""
    @State private var dueDate = Date.now
    @State private var usesAmount = true
    @State private var keepsDocument = true
    @State private var loaded = false
    @State private var viewing = false
    @State private var confirmsDelete = false
    @State private var addsBill = false
    @FocusState private var amountFocused: Bool

    private var amountCents: Int { Money.cents(from: amountText) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        DocumentThumbnail(statement: statement)
                            .onTapGesture { viewing = true }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("View the bill")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statement.fileName.isEmpty ? "Bill" : statement.fileName)
                                .font(.headline)
                                .lineLimit(2)
                            Text(sourceLine)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Label("Read on this \(DeviceName.current)", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CategoryColor.green.ink)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(CategoryColor.green.tint, in: .capsule)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Bill", selection: $billID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(bills) { bill in
                            Text(bill.name).tag(UUID?.some(bill.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if billID == nil {
                        Button("Add It as a New Bill") { addsBill = true }
                            .foregroundStyle(.primary)
                    }
                    LabeledContent("Amount due") {
                        TextField(Money.text(0), text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .focused($amountFocused)
                            .currencyEditing($amountText, isFocused: amountFocused)
                    }
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    if let start = statement.periodStart, let end = statement.periodEnd {
                        LabeledContent("Service period", value: "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
                    }
                }

                if !statement.charges.isEmpty {
                    Section("Charges on the bill") {
                        ForEach(statement.charges) { charge in
                            LabeledContent(charge.name) {
                                Text(Money.text(charge.amountCents)).monospacedDigit()
                            }
                        }
                        let sum = statement.charges.reduce(0) { $0 + $1.amountCents }
                        let matches = StatementMath.chargesMatch(statement.charges, amountCents: amountCents)
                        LabeledContent {
                            Text(matches ? "\(Money.text(sum)) ✓" : "\(Money.text(sum)), not \(Money.text(amountCents))")
                                .fontWeight(.bold)
                                .foregroundStyle(matches ? Brand.greenInk : CategoryColor.orange.ink)
                                .monospacedDigit()
                        } label: {
                            Text("Adds up to").fontWeight(.semibold)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $usesAmount) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use for \(dueDate.formatted(.dateTime.month(.wide)))’s bill")
                            Text(usesAmount ? "That due date is \(Money.text(amountCents))" : "It stays at the bill’s usual amount")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if statement.documentData != nil {
                        Toggle(isOn: $keepsDocument) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep the bill")
                                Text("It’s attached to the payment when it clears")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Apple’s on-device model read this bill. Check the amount and date; nothing about it left your \(DeviceName.current).")
                }

                Section {
                    Button("Delete This Bill", role: .destructive) { confirmsDelete = true }
                        .foregroundStyle(Brand.expenseInk)
                }
            }
            .navigationTitle(statement.isReviewed ? "Bill" : "New Bill")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") { save() }
                        .disabled(amountCents <= 0 || billID == nil)
                }
            }
            .alert("Delete this bill?", isPresented: $confirmsDelete) {
                Button("Delete", role: .destructive) {
                    context.delete(statement)
                    try? context.save()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only what Suffice read is deleted. The bill itself stays in your email or files.")
            }
            .sheet(isPresented: $viewing) { StatementDocumentView(statement: statement) }
            .sheet(isPresented: $addsBill) { BillEditor(bill: nil, suggestedName: statement.sender, suggestedAmountCents: amountCents, suggestedDue: dueDate) }
            .onChange(of: bills.map(\.id)) { old, new in
                // A bill just added from here is the one it's for.
                if billID == nil, let added = new.first(where: { !old.contains($0) }) { billID = added }
            }
            .onAppear(perform: load)
        }
    }

    private var sourceLine: String {
        let from = statement.sender.isEmpty ? "" : " from \(statement.sender)"
        switch statement.source {
        case .email: return "Email\(from) · \(statement.createdAt.formatted(.dateTime.month(.abbreviated).day()))"
        case .shared: return "Shared to Suffice · \(statement.createdAt.formatted(.dateTime.month(.abbreviated).day()))"
        case .scanned: return "Scanned · \(statement.createdAt.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        billID = statement.billID
        amountText = Money.field(statement.amountCents)
        dueDate = statement.dueDate
        usesAmount = statement.usesAmount
        keepsDocument = statement.documentData != nil
    }

    private func save() {
        statement.billID = billID
        statement.amountCents = amountCents
        statement.dueDate = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dueDate) ?? dueDate
        statement.usesAmount = usesAmount
        if !keepsDocument { statement.documentData = nil }
        statement.isReviewed = true
        try? context.save()
        dismiss()
    }
}

/// Reads a document that was just shared, scanned or picked, then shows it as a new bill.
struct BillImportSheet: View {
    let document: IncomingDocument
    var source: StatementSource = .shared
    /// The bill it's for, when it was added from that bill.
    var billID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var statement: BillStatement?
    @State private var problem: String?

    var body: some View {
        Group {
            if let statement {
                BillReadSheet(statement: statement)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let problem {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text(problem)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                            Text("Reading \(document.fileName)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { dismiss() }
                        }
                    }
                }
            }
        }
        .task { await read() }
    }

    private func read() async {
        guard statement == nil, problem == nil else { return }
        do {
            let added = try await BillStatements.add(document.data, type: document.type, fileName: document.fileName, source: source, in: context)
            // Started from a bill: it's for that one.
            if let billID, added.billID != billID {
                added.billID = billID
                try? context.save()
            }
            statement = added
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - The document

/// A small picture of a statement's first page.
struct DocumentThumbnail: View {
    let statement: BillStatement
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.text")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6))
            }
        }
        .frame(width: 74, height: 96)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
        .accessibilityLabel("The bill")
        .accessibilityHint("Opens it")
        .task(id: statement.id) {
            guard let data = statement.documentData else { return }
            if statement.documentType == "pdf",
               let page = PDFDocument(data: data)?.page(at: 0) {
                image = page.thumbnail(of: CGSize(width: 148, height: 192), for: .mediaBox)
            } else {
                image = UIImage(data: data)
            }
        }
    }
}

/// The statement itself: the PDF, or the scan, with Share.
struct StatementDocumentView: View {
    let statement: BillStatement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = statement.documentData {
                    if statement.documentType == "pdf" {
                        PDFKitView(data: data)
                    } else if let image = UIImage(data: data) {
                        ScrollView {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                } else {
                    ContentUnavailableView("Not kept", systemImage: "doc", description: Text("Only what Suffice read from this bill was saved."))
                }
            }
            .navigationTitle(statement.fileName.isEmpty ? "Bill" : statement.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                if let data = statement.documentData {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: StatementFile(data: data, type: statement.documentType, name: statement.fileName), preview: SharePreview(statement.fileName.isEmpty ? "Bill" : statement.fileName))
                            // Not a confirm button: the text color, not the app's (AGENT.md).
                            .tint(.primary)
                    }
                }
            }
        }
    }
}

/// A statement's file for the share sheet.
nonisolated struct StatementFile: Transferable {
    var data: Data
    var type: String
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { file in file.data }
            .exportingCondition { $0.type == "pdf" }
            .suggestedFileName("Bill.pdf")
        DataRepresentation(exportedContentType: .jpeg) { file in file.data }
            .exportingCondition { $0.type != "pdf" }
            .suggestedFileName("Bill.jpg")
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
