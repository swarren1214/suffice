import SwiftData
import SwiftUI

/// Add or change a bill or subscription and its schedule: once, or every N weeks, months or
/// years from its first due date, optionally ending on a date.
struct BillEditor: View {
    /// Nil to create a new bill.
    let bill: Bill?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var name = ""
    @State private var amountText = ""
    @State private var frequency: BillFrequency = .monthly
    @State private var interval = 1
    @State private var firstDue = Calendar.current.startOfDay(for: .now)
    @State private var endsOn = false
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    /// Custom was picked (or the saved schedule isn't one of the presets).
    @State private var isCustom = false
    @State private var color: CategoryColor = .blue
    @State private var categoryID: UUID?
    @State private var isAutopay = false
    @State private var isSubscription = false
    @State private var note = ""
    @State private var confirmsDelete = false
    @State private var pendingDelete = false

    init(bill: Bill?) {
        self.bill = bill
    }

    /// The common schedules, as in Calendar's Repeat menu.
    private enum Preset: Hashable, CaseIterable {
        case once, weekly, biweekly, monthly, quarterly, semiannual, yearly, custom

        var title: String {
            switch self {
            case .once: "Never (one time)"
            case .weekly: "Every week"
            case .biweekly: "Every 2 weeks"
            case .monthly: "Every month"
            case .quarterly: "Every 3 months"
            case .semiannual: "Every 6 months"
            case .yearly: "Every year"
            case .custom: "Custom"
            }
        }

        var schedule: (BillFrequency, Int)? {
            switch self {
            case .once: (.once, 1)
            case .weekly: (.weekly, 1)
            case .biweekly: (.weekly, 2)
            case .monthly: (.monthly, 1)
            case .quarterly: (.monthly, 3)
            case .semiannual: (.monthly, 6)
            case .yearly: (.yearly, 1)
            case .custom: nil
            }
        }

        static func matching(_ frequency: BillFrequency, _ interval: Int) -> Preset? {
            allCases.first { $0.schedule.map { $0.0 == frequency && $0.1 == interval } ?? false }
        }
    }

    private var preset: Binding<Preset> {
        Binding(
            get: { isCustom ? .custom : (Preset.matching(frequency, interval) ?? .custom) },
            set: { newValue in
                if let schedule = newValue.schedule {
                    isCustom = false
                    frequency = schedule.0
                    interval = schedule.1
                } else {
                    isCustom = true
                    if frequency == .once { frequency = .monthly }
                }
            }
        )
    }

    /// The schedule as it would be saved, for the summary line.
    private var draftRecord: BillRecord {
        let day = Calendar.current.component(.day, from: firstDue)
        return BillRecord(name: name, amountCents: 0, dueDay: day, frequency: frequency, interval: interval, startDate: firstDue, endDate: endsOn ? endDate : nil)
    }

    private var scheduleSummary: String {
        var text = BudgetMath.scheduleText(draftRecord)
        if frequency != .once {
            text += ", starting \(firstDue.formatted(.dateTime.month(.abbreviated).day().year()))"
            if endsOn { text += ", until \(endDate.formatted(.dateTime.month(.abbreviated).day().year()))" }
        }
        text += "."
        if frequency == .monthly || frequency == .yearly, Calendar.current.component(.day, from: firstDue) > 28 {
            text += " In shorter months it's due on the last day."
        }
        return text
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.cents(from: amountText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(name.first.map { String($0).uppercased() } ?? "?")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(color.ink, in: .circle)
                            .accessibilityHidden(true)
                        TextField("Name", text: $name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                    }
                    LabeledContent("Amount") {
                        TextField("$0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }

                Section {
                    Picker("Repeats", selection: preset) {
                        ForEach(Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    if isCustom {
                        Stepper(value: $interval, in: 1...52) {
                            Text("Every \(interval) \(frequency.unit)\(interval == 1 ? "" : "s")")
                                .monospacedDigit()
                        }
                        Picker("Unit", selection: $frequency) {
                            Text("Weeks").tag(BillFrequency.weekly)
                            Text("Months").tag(BillFrequency.monthly)
                            Text("Years").tag(BillFrequency.yearly)
                        }
                        .pickerStyle(.segmented)
                    }
                    DatePicker(frequency == .once ? "Due" : "First due", selection: $firstDue, displayedComponents: .date)
                    if frequency != .once {
                        Toggle("Ends", isOn: $endsOn.animation())
                        if endsOn {
                            DatePicker("Last due", selection: $endDate, in: firstDue..., displayedComponents: .date)
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleSummary)
                }

                Section {
                    CategoryPicker(title: "Category", selection: $categoryID, choices: CategoryChoice.budgetsAndSubcategories(categories))
                    Toggle("Autopay", isOn: $isAutopay)
                    Toggle("Subscription", isOn: $isSubscription)
                } footer: {
                    Text("Mark paid adds the payment to Activity in this category. Subscriptions are listed on their own.")
                }

                Section("Color") {
                    ColorChoiceGrid(selection: $color)
                        .padding(.vertical, 2)
                }

                Section {
                    TextField("Note", text: $note, axis: .vertical)
                }

                if bill != nil {
                    Section {
                        Button("Delete Bill", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(bill == nil ? "New bill" : "Edit bill")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Bill", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
            } message: {
                Text("Payments already recorded stay in Activity.")
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let bill else { return }
                context.delete(bill)
                try? context.save()
            }
        }
    }

    private func load() {
        guard let bill else { return }
        name = bill.name
        amountText = Money.editable(bill.amountCents)
        frequency = bill.frequency
        interval = max(bill.interval, 1)
        isCustom = Preset.matching(frequency, interval) == nil
        if bill.startDate > .distantPast {
            firstDue = bill.startDate
        } else {
            // Bills from before schedules: this month's due date on their day.
            firstDue = MonthSpan(containing: .now).dueDate(day: bill.dueDay)
        }
        if let end = bill.endDate {
            endsOn = true
            endDate = end
        }
        color = bill.color
        categoryID = bill.categoryID
        isAutopay = bill.isAutopay
        isSubscription = bill.isSubscription
        note = bill.note
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let cents = Money.cents(from: amountText) ?? 0
        let target: Bill
        if let bill {
            target = bill
        } else {
            target = Bill(name: trimmed, amountCents: cents, dueDay: Calendar.current.component(.day, from: firstDue))
            context.insert(target)
        }
        target.name = trimmed
        target.amountCents = cents
        let calendar = Calendar.current
        target.dueDay = calendar.component(.day, from: firstDue)
        target.startDate = calendar.startOfDay(for: firstDue)
        target.frequency = frequency
        target.interval = frequency == .once ? 1 : max(interval, 1)
        target.endDate = frequency != .once && endsOn ? calendar.startOfDay(for: endDate) : nil
        target.color = color
        target.categoryID = categoryID
        target.isAutopay = isAutopay
        target.isSubscription = isSubscription
        target.note = note
        try? context.save()
        dismiss()
    }
}

#Preview {
    BillEditor(bill: nil)
        .previewEnvironment()
}
