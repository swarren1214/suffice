import AuthenticationServices
import SwiftData
import SwiftUI

/// First run, from the "Suffice Onboarding & Tour" designs: Welcome, then six steps that end
/// with a real plan (who's budgeting, inviting your partner, accounts, the month's plan, bills,
/// reminders) and All set. "I Have an Invite" on Welcome is the partner's way in instead.
///
/// Onboarding is always dark, like the designs. Every step after Welcome can be skipped;
/// nothing is required but your name.
struct OnboardingView: View {
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @State private var flow = OnboardingFlow()
    @State private var household = HouseholdSync.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            screen
                .id(flow.screen)
                .transition(.asymmetric(
                    insertion: .move(edge: flow.isForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: flow.isForward ? .leading : .trailing).combined(with: .opacity)
                ))
        }
        .environment(flow)
        .environment(\.colorScheme, .dark)
        .tint(OnboardingStyle.accent)
        // Someone tapped a household invitation: show it here rather than as an alert.
        .onChange(of: household.pendingInvite != nil, initial: true) { _, invited in
            if invited, flow.screen != .invite { flow.go(to: .invite) }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch flow.screen {
        case .welcome: OnboardingWelcome()
        case .invite: OnboardingInvite()
        case .household: OnboardingHousehold()
        case .partner: OnboardingPartner()
        case .connect: OnboardingConnect()
        case .plan: OnboardingPlan()
        case .bills: OnboardingBills()
        case .alerts: OnboardingAlerts()
        case .ready: OnboardingReady { tour in
            UserDefaults.standard.set(tour, forKey: SettingsKey.wantsTour)
            AppRouter.shared.tab = .overview
            onboarded = true
        }
        }
    }
}

/// Where onboarding is, and what's been decided so far.
@Observable
final class OnboardingFlow {
    enum Screen: Hashable {
        case welcome, invite, household, partner, connect, plan, bills, alerts, ready
    }

    private(set) var screen: Screen = .welcome
    /// Which way the last move went, for the slide.
    private(set) var isForward = true

    // Who's budgeting
    var myName = ""
    var partnerName = ""
    var myPhoto: Data?
    var partnerPhoto: Data?
    /// The people saved so far, so going back and renaming updates them instead of adding more.
    var myID: UUID?
    var partnerID: UUID?

    // Plan and bills, worked out once from the bank history and kept while going back and forth.
    var planRows: [PlanRow]?
    var incomeText = ""
    var foundBills: [SpendingHistory.FoundBill]?
    var keptBills: Set<UUID> = []

    var partner: String? {
        let name = partnerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The numbered steps: Invite only when there's a partner to invite.
    var steps: [Screen] {
        var steps: [Screen] = [.household]
        if partner != nil { steps.append(.partner) }
        steps += [.connect, .plan, .bills, .alerts]
        return steps
    }

    func go(to screen: Screen) {
        move(to: screen, forward: true)
    }

    /// Sets the direction first and moves on the next turn of the run loop, so the screen
    /// leaving slides the right way too (its transition is read when it's removed).
    private func move(to screen: Screen, forward: Bool) {
        isForward = forward
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.35)) { self.screen = screen }
        }
    }

    func next() {
        switch screen {
        case .welcome, .invite: go(to: .household)
        case .alerts: go(to: .ready)
        case .ready: break
        default:
            guard let index = steps.firstIndex(of: screen), index + 1 < steps.count else { return go(to: .ready) }
            go(to: steps[index + 1])
        }
    }

    func back() {
        let previous: Screen
        if let index = steps.firstIndex(of: screen), index > 0 {
            previous = steps[index - 1]
        } else {
            previous = .welcome
        }
        move(to: previous, forward: false)
    }

    /// "2 of 6", for the step bar.
    var position: (number: Int, of: Int)? {
        steps.firstIndex(of: screen).map { (number: $0 + 1, of: steps.count) }
    }
}

/// One budget on Plan the month: an existing top-level budget, or a new one onboarding suggests.
struct PlanRow: Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var color: CategoryColor
    /// "Groceries, Fast food · avg $940"
    var hint: String
    /// What's typed in its amount field.
    var amountText: String
    /// Not a budget yet: Use This Plan adds it.
    var isNew = false
}

// MARK: - Look

/// The onboarding designs' colors and type.
enum OnboardingStyle {
    /// The readable column on iPad.
    static let columnWidth: CGFloat = 480
    /// Buttons.
    static let green = Color(hex: 0x0E8A34)
    /// Step bars, links, "This iPhone".
    static let accent = Color(hex: 0x5BD27A)
    static let card = Color(hex: 0x1C1C1E)
    static let secondaryText = Color(hex: 0xAEAEB2)
    static let tertiaryText = Color(hex: 0x98989F)
    static let divider = Color.white.opacity(0.08)
    /// The green wash at the top of Welcome.
    static let wash = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x0B6B2A), location: 0),
            .init(color: Color(hex: 0x06401A), location: 0.3),
            .init(color: .black, location: 0.58),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// The pill buttons from the designs: solid green, translucent, white, or plain text.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, white, plain }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .plain ? 16 : 17, weight: kind == .secondary || kind == .plain ? .semibold : .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: kind == .plain ? 44 : (kind == .secondary ? 50 : 54))
            .background {
                switch kind {
                case .primary: Capsule().fill(OnboardingStyle.green)
                case .secondary: Capsule().fill(.white.opacity(0.10)).overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                case .white: Capsule().fill(.white)
                case .plain: Color.clear
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .white: Brand.greenInk
        default: .white
        }
    }
}

extension ButtonStyle where Self == OnboardingButtonStyle {
    static func onboarding(_ kind: OnboardingButtonStyle.Kind = .primary) -> OnboardingButtonStyle {
        OnboardingButtonStyle(kind: kind)
    }
}

/// A numbered step: back button, step bar and "2 of 6" across the top, a big title and a line
/// under it, the screen's content scrolling, and its buttons pinned to the bottom.
struct OnboardingStep<Content: View, Controls: View>: View {
    var title: String
    var subtitle: String
    var content: Content
    var controls: Controls
    @Environment(OnboardingFlow.self) private var flow

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 32, weight: .heavy))
                            .tracking(-0.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(OnboardingStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: OnboardingStyle.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .bottom)

            VStack(spacing: 10) { controls }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: OnboardingStyle.columnWidth)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: flow.back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            if let position = flow.position {
                HStack(spacing: 6) {
                    ForEach(1...position.of, id: \.self) { index in
                        Capsule()
                            .fill(index <= position.number ? OnboardingStyle.accent : .white.opacity(0.16))
                            .frame(height: 5)
                    }
                }
                .animation(.smooth, value: position.number)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(position.number) of \(position.of)")

                Text("\(position.number) of \(position.of)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: OnboardingStyle.columnWidth)
        .frame(maxWidth: .infinity)
    }
}

/// A rounded dark card holding rows.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(OnboardingStyle.card, in: .rect(cornerRadius: 24, style: .continuous))
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

/// The hairline between rows in a card, starting after the row's icon.
struct OnboardingDivider: View {
    var inset: CGFloat = 64

    var body: some View {
        Rectangle()
            .fill(OnboardingStyle.divider)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// A round badge with a letter or symbol on a category's dark tint, as in the designs' lists.
struct OnboardingInitial: View {
    var text: String
    var color: CategoryColor
    var size: CGFloat = 38

    var body: some View {
        Text(text.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(color.color)
            .frame(width: size, height: size)
            .background(color.color.opacity(0.2), in: .circle)
            .accessibilityHidden(true)
    }
}

/// A text link with a plus, like "Add a Budget".
struct OnboardingAddLink: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingStyle.accent)
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

/// The adaptive Sign in with Apple button style: black in light mode, white in dark mode.
struct AdaptiveSignInStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    }
}

#Preview {
    OnboardingView()
        .previewEnvironment()
}
