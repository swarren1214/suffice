import SwiftData
import SwiftUI

/// Add or change something owned that isn't a bank account: a home, a car, a 401(k). Its value
/// is the household's own estimate.
struct AssetEditor: View {
    let asset: OwnedAsset?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \OwnedAsset.sortOrder) private var assets: [OwnedAsset]

    @State private var name = ""
    @State private var kind: AssetKind = .home
    @State private var valueText = ""
    @State private var note = ""
    @State private var loadedValue: Int?
    @State private var confirmsDelete = false
    @State private var pendingDelete = false
    /// Filled in once; coming back from the Type list shows the editor again.
    @State private var loaded = false
    @FocusState private var valueFocused: Bool

    private var valueCents: Int { Money.cents(from: valueText) ?? 0 }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && valueCents > 0 }

    /// Picking a type brings its name, unless the name was changed.
    private var kindChoice: Binding<AssetKind> {
        Binding(
            get: { kind },
            set: { new in
                if name.isEmpty || name == kind.name { name = new.name }
                kind = new
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        WealthIcon(symbol: kind.symbol, color: kind.color, size: 48)
                        TextField("Name", text: $name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                    }
                    Picker("Type", selection: kindChoice) {
                        ForEach(AssetKind.allCases) { option in
                            Label(option.name, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    LabeledContent("Worth today") {
                        TextField(Money.text(0), text: $valueText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($valueFocused)
                            .currencyEditing($valueText, isFocused: valueFocused)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                } footer: {
                    Text(footer)
                }

                if asset != nil {
                    Section {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label("Delete", systemImage: "trash")
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
            .navigationTitle(asset == nil ? "New Asset" : "Asset")
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
            .alert("Delete this asset?", isPresented: $confirmsDelete) {
                Button("Delete", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It comes off Net Worth.")
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let asset else { return }
                context.delete(asset)
                try? context.save()
            }
        }
    }

    private var footer: String {
        switch kind {
        case .home: "What it would sell for today, by your estimate. Zillow or Redfin can help."
        case .vehicle: "What it would sell for today. Kelley Blue Book or Edmunds can help."
        case .investment: "The account’s balance from its latest statement."
        case .other: "What it would sell for today, by your estimate."
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let asset else {
            name = kind.name
            return
        }
        name = asset.name
        kind = asset.kind
        valueText = Money.field(asset.valueCents)
        loadedValue = asset.valueCents
        note = asset.note
    }

    private func save() {
        let target: OwnedAsset
        if let asset {
            target = asset
        } else {
            target = OwnedAsset(name: "", kind: kind, valueCents: 0, sortOrder: (assets.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        if valueCents != loadedValue {
            target.valueCents = valueCents
            target.valueDate = .now
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.note = note
        try? context.save()
        dismiss()
    }
}

#Preview {
    AssetEditor(asset: nil)
        .previewEnvironment()
}
