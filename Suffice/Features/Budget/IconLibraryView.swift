import SwiftUI

/// Every budget icon, grouped (Home, Food & drink, Transportation…) with a search field that
/// matches names and everyday words ("rent", "vet", "netflix"). Picking one goes back.
struct IconLibraryView: View {
    @Binding var selection: String
    var color: CategoryColor
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(SymbolChoices.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.secondaryText)
                                .padding(.leading, 4)
                            grid(section.symbols)
                        }
                    }
                }
                .padding(16)
            } else {
                let results = SymbolChoices.search(query)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    grid(results).padding(16)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search icons, like rent or vet")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    private func grid(_ symbols: [SymbolOption]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(symbols) { option in
                IconChoiceButton(name: option.name, isSelected: option.name == selection, color: color, background: Color(.secondarySystemGroupedBackground)) {
                    selection = option.name
                    dismiss()
                }
                .accessibilityLabel(option.accessibilityName)
            }
        }
    }
}

/// One icon in a choice grid: the selected one in the budget's color on its tint.
struct IconChoiceButton: View {
    var name: String
    var isSelected: Bool
    var color: CategoryColor
    /// Gray on a white card; white on the grouped background of the library.
    var background: Color = Color(.systemGray6)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isSelected ? color.ink : Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? color.tint : background, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        IconLibraryView(selection: .constant("house"), color: .orange)
    }
}
