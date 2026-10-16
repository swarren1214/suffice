import SwiftUI
import UIKit

/// One card in Overview's carousel: All accounts first, then each account.
struct AccountCardItem: Identifiable {
    enum Content {
        /// Total cash, this month's income and expenses, and how many accounts are in the budget.
        case total(cash: Int, income: Int, expenses: Int, included: Int, count: Int)
        case account(Account, balance: Int)
    }

    var id: String
    var content: Content
    var palette: CardPalette
    /// The bank's logo, once it's loaded.
    var logo: UIImage?
    var accessibilityLabel: String

    static let allID = "all"
}

/// Overview's account switcher: cards side by side, swiped like cards in Wallet. The front
/// card floats (it rises, falls and tilts, with a shine passing over it), as widgets do in the
/// widget gallery; the ones beside it sit smaller and turned away. Tap a side card to bring it
/// forward. With Reduce Motion on, nothing floats.
struct AccountCarousel: View {
    var items: [AccountCardItem]
    @Binding var selection: String
    var cardWidth: CGFloat

    @State private var dragX: CGFloat = 0
    /// True while a finger is down; a drag the system cancels never ends, so this resets it.
    @GestureState private var isDragging = false

    init(items: [AccountCardItem], selection: Binding<String>, cardWidth: CGFloat) {
        self.items = items
        self._selection = selection
        self.cardWidth = cardWidth
    }

    private var index: Int { items.firstIndex { $0.id == selection } ?? 0 }
    private var gap: CGFloat { cardWidth * 0.8 }
    static func cardHeight(for width: CGFloat) -> CGFloat { (width / 1.59).rounded() }

    var body: some View {
        let height = Self.cardHeight(for: cardWidth)
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                let offset = CGFloat(position - index) * gap + dragX
                let t = max(-1.6, min(1.6, offset / gap))
                let distance = min(abs(t), 1)
                FloatingCard(isActive: position == index, width: cardWidth) {
                    AccountCardFace(item: item)
                }
                .frame(width: cardWidth, height: height)
                .scaleEffect(1 - distance * 0.14)
                .rotation3DEffect(.degrees(-t * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .offset(x: offset, y: distance * 10)
                // Fades in from two away, so nothing pops in mid-swipe.
                .opacity(abs(t) <= 1 ? 1 - distance * 0.35 : 0.65 * max(0, (1.5 - abs(t)) / 0.5))
                .zIndex(100 - abs(t) * 10)
                .onTapGesture { select(position) }
                .allowsHitTesting(abs(t) <= 1.2)
            }
        }
        .frame(maxWidth: .infinity)
        // Room above and below for the float and the shadow, so the card never reaches the title.
        .frame(height: height + 48)
        .contentShape(.rect)
        .gesture(drag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.indices.contains(index) ? items[index].accessibilityLabel : "")
        .accessibilityValue("\(index + 1) of \(items.count)")
        .accessibilityHint("Swipe up or down to switch accounts")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(index + 1)
            case .decrement: select(index - 1)
            @unknown default: break
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: isDragging) { _, dragging in
            if !dragging, dragX != 0 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { dragX = 0 }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                var dx = value.translation.width
                // At either end it stretches and gives way, then springs back.
                if (index == 0 && dx > 0) || (index == items.count - 1 && dx < 0) { dx *= 0.35 }
                dragX = dx
            }
            .onEnded { value in
                let moved = value.translation.width
                let flung = value.predictedEndTranslation.width
                var target = index
                if moved < -gap * 0.22 || flung < -gap * 0.6 { target += 1 }
                if moved > gap * 0.22 || flung > gap * 0.6 { target -= 1 }
                target = min(max(target, 0), items.count - 1)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    if items.indices.contains(target) { selection = items[target].id }
                    dragX = 0
                }
            }
    }

    private func select(_ position: Int) {
        guard items.indices.contains(position), position != index else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            selection = items[position].id
        }
    }
}

/// The front card's float: a slow rise and fall with a gentle 3D tilt, a shine sweeping
/// across, and a shadow underneath that shrinks as the card lifts. Coming to the front, a card
/// eases into it; leaving, it settles. The clock pauses for the cards beside it.
private struct FloatingCard<Content: View>: View {
    var isActive: Bool
    var width: CGFloat
    var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isActive: Bool, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.width = width
        self.content = content()
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive || reduceMotion)) { timeline in
            content.modifier(FloatPose(
                time: timeline.date.timeIntervalSinceReferenceDate,
                motion: isActive && !reduceMotion ? 1 : 0,
                shadow: isActive ? 1 : 0,
                width: width
            ))
        }
    }
}

/// Where the float is at `time`, scaled by `motion` (0 still, 1 floating) so it can ease in
/// and out with the selection's animation.
private struct FloatPose: ViewModifier, Animatable {
    var time: Double
    var motion: Double
    var shadow: Double
    var width: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(motion, shadow) }
        set { motion = newValue.first; shadow = newValue.second }
    }

    func body(content: Content) -> some View {
        // The tilt circles the card: toward one corner, then the next, all the way around,
        // with the top-bottom and left-right tilts a quarter turn apart. The rise and fall
        // keeps its own slower beat, so the two never line up into a simple rock.
        let orbit = time / 8 * 2 * .pi
        let tiltX = cos(orbit) * 5.5
        let tiltY = sin(orbit) * 6.5
        let bob = cos(time / 5.2 * 2 * .pi)
        content
            .overlay {
                // The light gathers on whichever edge is tipped toward you: a positive X tilt
                // brings the bottom forward, a positive Y tilt the left.
                CardLight(x: 0.5 - 0.35 * tiltY / 6.5, y: 0.5 + 0.35 * tiltX / 5.5)
                    .opacity(motion)
            }
            .rotation3DEffect(.degrees(tiltX * motion), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(tiltY * motion), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotationEffect(.degrees(0.6 * sin(orbit) * motion))
            .offset(y: (-6 + 6 * bob) * motion)
            // Laid out before the offset, so the shadow stays put while the card rises.
            .background(alignment: .bottom) {
                FloatShadow(width: width * 0.77)
                    .scaleEffect(1 - (0.08 - 0.08 * bob) * motion)
                    .opacity(shadow * (0.45 - (0.02 - 0.12 * bob) * motion))
            }
    }
}

private struct FloatShadow: View {
    var width: CGFloat

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(0.85), .black.opacity(0)], center: .center, startRadius: 0, endRadius: width / 2))
            .frame(width: width, height: 20)
            .blur(radius: 4)
            .offset(y: 30)
            .accessibilityHidden(true)
    }
}

/// A soft pool of light on the card, as if a lamp were shining on it, at a point given as a
/// share of the card's width and height. It brightens the card's own color (soft light) with a
/// touch of plain glow on top, so it shows on dark cards and light ones alike.
private struct CardLight: View {
    var x: Double
    var y: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width * 0.85
            let center = CGPoint(x: proxy.size.width * x, y: proxy.size.height * y)
            ZStack {
                spot(size: size)
                    .blendMode(.softLight)
                spot(size: size * 0.8)
                    .opacity(0.22)
                    .blendMode(.screen)
            }
            .position(center)
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func spot(size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [.white, .white.opacity(0.45), .white.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: size / 2
            ))
            .frame(width: size, height: size)
            .blur(radius: 20)
    }
}

/// A card's face: the bank's logo and name, then either Total cash or the account's name, last
/// four digits and balance. Text is black or white, whichever the palette says reads better.
struct AccountCardFace: View {
    var item: AccountCardItem

    private var ink: Color { item.palette.ink.color }
    private var isDarkText: Bool { item.palette.isDarkText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                tile
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                badge
            }
            Spacer(minLength: 8)
            switch item.content {
            case let .total(cash, income, expenses, _, _):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total cash")
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.72)
                    Text(Money.text(cash))
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(-0.8)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    HStack(spacing: 14) {
                        figure("Income", Money.whole(income))
                        figure("Expenses", Money.whole(expenses))
                    }
                    .padding(.top, 2)
                }
            case let .account(account, balance):
                VStack(alignment: .leading, spacing: 12) {
                    if account.kind == .credit { chip }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name.isEmpty ? account.kind.name : account.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text(account.mask.isEmpty ? account.source.label : "•••• \(account.mask)")
                                .font(.system(size: 13))
                                .tracking(1.5)
                                .opacity(0.72)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(balanceLabel(account))
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.72)
                            Text(Money.text(balance))
                                .font(.system(size: 24, weight: .heavy))
                                .tracking(-0.4)
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(item.palette.face)
                Circle()
                    .fill(.white.opacity(isDarkText ? 0.32 : 0.09))
                    .frame(width: 240, height: 240)
                    .offset(x: 60, y: -80)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 12)
        .accessibilityHidden(true)
    }

    private var title: String {
        switch item.content {
        case .total: "All accounts"
        case .account(let account, _):
            account.kind == .cash ? "Cash" : (account.institution.isEmpty ? account.name : account.institution)
        }
    }

    @ViewBuilder
    private var tile: some View {
        switch item.content {
        case .total:
            Image("SufficeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        case .account(let account, _):
            if let logo = item.logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 9, style: .continuous))
            } else {
                Text(account.kind == .cash ? "$" : String(title.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .frame(width: 30, height: 30)
                    .background((isDarkText ? Color.black : Color.white).opacity(isDarkText ? 0.12 : 0.2), in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder((isDarkText ? Color.black : Color.white).opacity(isDarkText ? 0.18 : 0.3)))
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch item.content {
        case let .total(_, _, _, included, count):
            Text("\(included) of \(count)")
                .font(.system(size: 12, weight: .bold))
                .opacity(0.72)
        case .account(let account, _):
            if account.includeInBudget {
                Text(account.kind == .cash ? "BY HAND" : account.kind.name.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .opacity(0.72)
            } else {
                Text("Not in budget")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((isDarkText ? Color.black.opacity(0.12) : Color.white.opacity(0.2)), in: .capsule)
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xE6D292), Color(hex: 0xC9AE5D)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 28)
                .overlay {
                    Path { path in
                        for y in [10.0, 18.0] {
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: 12, y: y))
                            path.move(to: CGPoint(x: 26, y: y)); path.addLine(to: CGPoint(x: 38, y: y))
                        }
                        path.move(to: CGPoint(x: 12, y: 0)); path.addLine(to: CGPoint(x: 12, y: 28))
                        path.move(to: CGPoint(x: 26, y: 0)); path.addLine(to: CGPoint(x: 26, y: 28))
                        path.move(to: CGPoint(x: 12, y: 14)); path.addLine(to: CGPoint(x: 26, y: 14))
                    }
                    .stroke(.black.opacity(0.25), lineWidth: 1)
                }
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.2)))
            Image(systemName: "wave.3.right")
                .font(.system(size: 15, weight: .semibold))
                .opacity(0.7)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).opacity(0.72)
            Text(value).fontWeight(.bold)
        }
        .font(.system(size: 13))
    }

    private func balanceLabel(_ account: Account) -> String {
        switch account.kind {
        case .credit: "Balance"
        case .cash: "On hand"
        default: "Available"
        }
    }
}

/// The page dots under the carousel, with arrows either side. Long lists show "3 of 12"
/// instead of a row of dots.
struct CardPager: View {
    var count: Int
    var index: Int
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(count: Int, index: Int, select: @escaping (Int) -> Void) {
        self.count = count
        self.index = index
        self.select = select
    }

    private var color: Color { colorScheme == .dark ? .white : Brand.greenInk }

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", label: "Previous account", target: index - 1)
            if count <= 9 {
                ForEach(0..<count, id: \.self) { position in
                    Button { select(position) } label: {
                        Capsule()
                            .fill(color.opacity(position == index ? 1 : 0.32))
                            .frame(width: position == index ? 20 : 7, height: 7)
                            .frame(width: 20, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            } else {
                Text("\(index + 1) of \(count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .frame(minWidth: 60)
            }
            arrow("chevron.right", label: "Next account", target: index + 1)
        }
        .animation(.smooth(duration: 0.3), value: index)
    }

    private func arrow(_ symbol: String, label: String, target: Int) -> some View {
        Button { select(target) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity((0..<count).contains(target) ? 1 : 0.3)
        .disabled(!(0..<count).contains(target))
        .accessibilityLabel(label)
    }
}
