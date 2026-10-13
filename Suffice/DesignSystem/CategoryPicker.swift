import SwiftUI

/// A budget's icon in its color, on a soft circle of the same color. Used wherever a category is
/// chosen or shown in a list, so a budget always looks the same.
struct CategoryIcon: View {
    var symbol: String
    var color: CategoryColor
    var size: CGFloat = 30

    init(symbol: String, color: CategoryColor, size: CGFloat = 30) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    init(_ category: BudgetCategory, size: CGFloat = 30) {
        self.init(symbol: category.symbol, color: category.color, size: size)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(color.ink)
            .frame(width: size, height: size)
            .background(color.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

/// One choice in a category picker.
struct CategoryChoice: Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var color: CategoryColor
    /// A subcategory, drawn indented under its budget.
    var isSubcategory = false

    init(_ category: BudgetCategory, isSubcategory: Bool = false) {
        id = category.id
        name = category.name
        symbol = category.symbol
        color = category.color
        self.isSubcategory = isSubcategory
    }

    /// Every budget, each followed by its subcategories.
    static func budgetsAndSubcategories(_ categories: [BudgetCategory]) -> [CategoryChoice] {
        let live = categories.filter { !$0.isArchived }
        return live.filter { $0.parentID == nil }.flatMap { parent in
            [CategoryChoice(parent)] + live.filter { $0.parentID == parent.id }.map { CategoryChoice($0, isSubcategory: true) }
        }
    }

    /// Only top-level budgets.
    static func budgets(_ categories: [BudgetCategory]) -> [CategoryChoice] {
        categories.filter { $0.parentID == nil && !$0.isArchived }.map { CategoryChoice($0) }
    }
}

/// A form row that opens a list of categories, each with its icon in its color and the
/// checkmark on the right. Shows the chosen category's icon and name in the row.
struct CategoryPicker: View {
    var title: String
    @Binding var selection: UUID?
    var choices: [CategoryChoice]
    var noneTitle = "None"
    /// Outside a List or Form there's no automatic chevron, so draw one.
    var isInList = true

    var body: some View {
        if isInList {
            link
        } else {
            link.buttonStyle(.plain)
        }
    }

    private var link: some View {
        let selected = choices.first { $0.id == selection }
        return NavigationLink {
            CategoryChoiceList(title: title, selection: $selection, choices: choices, noneTitle: noneTitle)
        } label: {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let selected {
                    CategoryIcon(symbol: selected.symbol, color: selected.color, size: 24)
                    Text(selected.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(noneTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !isInList {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityValue(selected?.name ?? noneTitle)
    }
}

private struct CategoryChoiceList: View {
    var title: String
    @Binding var selection: UUID?
    var choices: [CategoryChoice]
    var noneTitle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row(id: nil) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text(noneTitle)
                }
                ForEach(choices) { choice in
                    row(id: choice.id) {
                        CategoryIcon(symbol: choice.symbol, color: choice.color)
                        Text(choice.name)
                    }
                    .padding(.leading, choice.isSubcategory ? 28 : 0)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(id: UUID?, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = selection == id
        return Button {
            selection = id
            dismiss()
        } label: {
            HStack(spacing: 12) {
                content()
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Brand.green)
                }
            }
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
