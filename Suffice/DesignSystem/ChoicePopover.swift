import SwiftUI

/// One row in a ChoicePopover.
struct ChoiceItem: Identifiable {
    var id: String
    var title: String
    var systemImage: String?
    var isSelected = false
    var isEnabled = true
    var action: () -> Void
}

/// A toolbar button that opens a small glass popover of choices: icons and text in the same
/// color, and the checkmark on the right. Used instead of a system Menu where a selection is
/// shown, since iOS 26 menus put the checkmark on the left and tint the icons.
struct ChoicePopoverButton<Label: View>: View {
    /// Groups of rows, separated by a divider.
    var sections: [[ChoiceItem]]
    var maxHeight: CGFloat = 520
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false

    init(sections: [[ChoiceItem]], maxHeight: CGFloat = 520, @ViewBuilder label: @escaping () -> Label) {
        self.sections = sections
        self.maxHeight = maxHeight
        self.label = label
    }

    var body: some View {
        Button { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sections.indices, id: \.self) { index in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(height: 6)
                                    .opacity(0.35)
                            }
                            ForEach(Array(sections[index].enumerated()), id: \.element.id) { offset, item in
                                if offset > 0 {
                                    Divider().padding(.leading, 16)
                                }
                                ChoiceRow(item: item) {
                                    item.action()
                                    isPresented = false
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 260)
                .frame(maxHeight: maxHeight)
                .presentationCompactAdaptation(.popover)
            }
    }
}

private struct ChoiceRow: View {
    var item: ChoiceItem
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                if let systemImage = item.systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 22)
                }
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
            .font(.body)
            .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }
}
