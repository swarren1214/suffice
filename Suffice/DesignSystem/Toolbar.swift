import SwiftUI

/// The glass month capsule at the top left of every tab: a calendar icon, the month and a chevron. It opens a
/// small glass popover with the months of a year as a 3×4 grid of short names, and the years
/// underneath. Picking a year changes the grid; picking a month goes there. Months after this
/// one are disabled, since there's nothing to budget there yet.
struct MonthMenu: View {
    @Environment(AppRouter.self) private var router
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.callout.weight(.semibold))
                Text(router.month.start.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.callout.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
        .accessibilityLabel("Change month, \(router.month.start.formatted(.dateTime.month(.wide).year()))")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            MonthGrid(selected: router.month) { span in
                withAnimation(.snappy) { router.month = span }
                isPresented = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The popover's content: twelve month squares, then the years.
private struct MonthGrid: View {
    let selected: MonthSpan
    let choose: (MonthSpan) -> Void
    @State private var year: Int

    /// How many years back the picker reaches.
    private static let yearsBack = 10

    init(selected: MonthSpan, choose: @escaping (MonthSpan) -> Void) {
        self.selected = selected
        self.choose = choose
        _year = State(initialValue: Calendar.current.component(.year, from: selected.start))
    }

    var body: some View {
        let calendar = Calendar.current
        let now = MonthSpan(containing: .now)
        let thisYear = calendar.component(.year, from: now.start)
        let years = Array((thisYear - Self.yearsBack)...thisYear)

        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let span = Self.span(year: year, month: month, calendar: calendar)
                    MonthSquare(
                        title: span.start.formatted(.dateTime.month(.abbreviated)),
                        isSelected: span == selected,
                        isCurrent: span == now,
                        isEnabled: span.start <= now.start
                    ) {
                        choose(span)
                    }
                    .accessibilityLabel(span.start.formatted(.dateTime.month(.wide).year()))
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(years, id: \.self) { option in
                            Button {
                                withAnimation(.snappy) {
                                    year = option
                                    proxy.scrollTo(option, anchor: .center)
                                }
                            } label: {
                                Text(String(option))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(option == year ? Color.white : Color.primary)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 34)
                                    .background(option == year ? Brand.green : Color.primary.opacity(0.06), in: .capsule)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .id(option)
                            .accessibilityAddTraits(option == year ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(year, anchor: .center) }
            }
        }
        .padding(14)
        .frame(width: 292)
    }

    private static func span(year: Int, month: Int, calendar: Calendar) -> MonthSpan {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
        return MonthSpan(containing: date, calendar: calendar)
    }
}

/// One month in the grid: green when it's the month showing, outlined when it's this month,
/// faded when it's still ahead.
private struct MonthSquare: View {
    var title: String
    var isSelected: Bool
    var isCurrent: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : (isEnabled ? Color.primary : Color.secondary.opacity(0.5)))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(isSelected ? Brand.green : Color.primary.opacity(isEnabled ? 0.06 : 0.03), in: .rect(cornerRadius: 14))
                .overlay {
                    if isCurrent && !isSelected {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.green, lineWidth: 1.5)
                    }
                }
                .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The ✨ button at the top right of every tab: opens Ask Suffice. Hidden on devices that can't
/// run the on-device model.
struct AskButton: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        if OnDeviceModel.availability != .unsupported {
            Button {
                router.showsAsk = true
            } label: {
                // Titled, so it reads right if it's folded into the bar's "…" menu.
                Label("Ask Suffice", systemImage: "sparkles")
                    .foregroundStyle(.white)
            }
        }
    }
}

/// The person's photo at the top right: the shared Hearth profile button (HearthProfile.swift),
/// the same in every Hearth app. Opens the Profile sheet.
struct ProfileButton: View {
    var body: some View {
        HearthProfileButton()
    }
}

extension View {
    /// The standard top bar for a tab: month capsule on the left; Ask, the screen's action and
    /// the profile avatar sharing a glass capsule on the right.
    func tabToolbar<Action: View>(@ViewBuilder action: @escaping () -> Action) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                MonthMenu()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // White icons, also in the "…" menu if the bar runs out of room (the app's tint
                // is green, which made menu icons green beside white text).
                AskButton().tint(.white)
                action().tint(.white)
                ProfileButton()
            }
        }
    }
}
