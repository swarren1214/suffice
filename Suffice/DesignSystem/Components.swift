import SwiftUI

// The pieces every Suffice screen is built from, matching the MVP v2 designs: the green
// gradient header, white 26 pt cards, amount pills, merchant avatars with who-badges, budget
// rings, and the glass controls that sit over the green.

/// The green header that fades into the gray background. Fixed behind the scroll view.
struct HeaderGradient: View {
    var height: CGFloat = 330

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Brand.greenDeep, location: 0),
                .init(color: Brand.greenMid, location: 0.58),
                .init(color: Brand.greenMid.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
    }
}

/// A tab's screen: the green header with a big white title (and an optional figure on the
/// right, like "$1,450.17 left"), then cards. Toolbar items come from the caller. On iPad the
/// content keeps to a readable column in the middle while the green runs edge to edge.
struct GreenScreen<Content: View>: View {
    /// The widest the cards get (iPad, Mac). iPhones are narrower than this.
    static var readableWidth: CGFloat { 820 }

    var title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) { HeaderGradient() }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // The title is drawn large in the content, as in the designs.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }
}

/// The Liquid Glass card at the top of each tab, over the green header: a small header line,
/// a big figure, then whatever detail the tab needs.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// The glass card's top line: a bold label on the left, a quiet note on the right.
struct GlassCardHeader: View {
    var title: String
    var note: String?

    var body: some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            if let note { Text(note) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// The glass card's big number.
struct GlassFigure: View {
    var text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(color)
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

/// A small figure in a soft tile inside the glass card ("Income $6,400").
struct GlassTile: View {
    var title: String
    var value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 18))
    }
}

/// A white card with the designs' 26 pt corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
    }
}

/// A list inside a white card, with hairlines between rows.
struct CardList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    var items: Data
    var inset: CGFloat = 16
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, inset)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
    }
}

/// "Accounts", "Upcoming": the 22 pt section titles, with an optional control on the right.
struct SectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

/// A small tinted capsule button, like Accounts › Add.
struct TintedCapsuleButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.bold))
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.green)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Brand.green.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The red (spent) or green (received) amount capsule on transaction rows.
struct AmountPill: View {
    var cents: Int
    var kind: EntryKind

    var body: some View {
        Text(kind == .income ? "+" + Money.text(cents) : Money.text(cents))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(kind == .income ? Brand.green : Brand.expense, in: .capsule)
            .accessibilityLabel(kind == .income ? "Received \(Money.text(cents))" : "Spent \(Money.text(cents))")
    }
}

/// A merchant's initial on its color, with the person who spent it badged in the corner.
struct MerchantAvatar: View {
    var name: String
    var isIncome = false
    var member: Member?
    var size: CGFloat = 40
    /// The merchant's logo (bank-synced transactions). The initial shows until it loads, or
    /// when there isn't one.
    var logoURL: String? = nil

    var body: some View {
        initial
            .overlay {
                if let url = logoURL.flatMap(URL.init(string:)) {
                    MerchantLogoImage(url: url, size: size)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let member {
                    MemberBadge(member: member, size: size * 0.5)
                        .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                        .offset(x: 4, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(isIncome ? Brand.green : MerchantColor.color(for: name), in: .circle)
    }
}

/// Steady colors for merchants: the same payee always gets the same color.
enum MerchantColor {
    static let palette: [UInt32] = [0xC8102E, 0x0063B2, 0xB0006D, 0x00843D, 0xC25E00, 0x1D4ED8, 0x0E3E8C, 0x5B3FD9, 0x8A6D00, 0x0E5FA8, 0xB9461F]

    static func color(for name: String) -> Color {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        // A small stable hash (String.hashValue changes every launch).
        let sum = key.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Color(hex: palette[Int(sum % UInt32(palette.count))])
    }
}

/// A household member's photo, or their initial in their pale circle.
struct MemberBadge: View {
    var member: Member
    var size: CGFloat = 30

    var body: some View {
        PersonAvatar(member: member, size: size)
            .accessibilityLabel(member.name)
    }
}

/// A budget's ring with its icon inside, as on the Budget screen.
struct CategoryRing: View {
    var progress: Double
    var color: CategoryColor
    var symbol: String
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray6), lineWidth: size * 0.104)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color.color, style: StrokeStyle(lineWidth: size * 0.104, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(color.color)
        }
        .padding(size * 0.042)
        .frame(width: size, height: size)
        .animation(.smooth, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((min(progress, 9.99) * 100).rounded())) percent spent")
    }
}

/// A thin bar for a subcategory's spending against its amount.
struct ProgressBar: View {
    var progress: Double
    var color: Color
    var track: Color = Color(.systemGray6)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: progress)
        .accessibilityHidden(true)
    }
}

/// The category chip on the transaction sheet: dot, name, up-down chevron.
struct CategoryPill: View {
    var name: String
    var color: CategoryColor?
    /// The budget's icon; a dot when there's no budget yet.
    var symbol: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = color ?? .gray
        // The pale tint and dark ink read well on white; in dark mode they'd glare, so the pill
        // becomes a translucent wash of the color with the bright color as text.
        let isDark = colorScheme == .dark
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
            } else {
                Circle().fill(palette.color).frame(width: 9, height: 9)
            }
            Text(name)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isDark ? palette.color : palette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isDark ? palette.color.opacity(0.22) : palette.tint, in: .capsule)
    }
}

/// An empty state inside a card.
struct EmptyCard: View {
    var systemName: String
    var title: String
    var message: String
    /// Liquid Glass instead of white, for when it's the first thing over the green header.
    var isGlass = false

    var body: some View {
        if isGlass {
            GlassCard { content }
        } else {
            Card { content }
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.largeTitle)
                .foregroundStyle(Brand.green)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// The logo's three strokes, from the WeBudget designs.
struct BrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 26 × 22 grid.
        let sx = rect.width / 26, sy = rect.height / 22
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: rect.minX + x1 * sx, y: rect.minY + y1 * sy))
            path.addLine(to: CGPoint(x: rect.minX + x2 * sx, y: rect.minY + y2 * sy))
        }
        line(3, 3, 9, 19)
        line(11, 3, 17, 19)
        line(19, 3, 22, 11)
        return path
    }
}

extension BrandMark {
    /// The mark at a given width, stroked white.
    static func image(width: CGFloat, color: Color = .white) -> some View {
        BrandMark()
            .stroke(color, style: StrokeStyle(lineWidth: width * 0.146, lineCap: .round))
            .frame(width: width, height: width * 22 / 26)
            .accessibilityHidden(true)
    }
}

/// The app icon for the sign-in screen (as in Hearken). The images are Icon Composer's own
/// exports, light and dark, already shaped, so nothing is clipped here.
struct AppIconBadge: View {
    var size: CGFloat = 92

    var body: some View {
        Image("SufficeMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Brand.green.opacity(0.3), radius: 15, y: 10)
            .accessibilityHidden(true)
    }
}
