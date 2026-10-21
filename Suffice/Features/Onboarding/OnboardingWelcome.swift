import SwiftUI

/// Welcome: the promise, a glimpse of the app (what's left to spend, a budget, a bill), and Get
/// Started. Joining the family's budget happens in the household step (its invitation).
struct OnboardingWelcome: View {
    @Environment(OnboardingFlow.self) private var flow
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @State private var height: CGFloat = 844

    /// iPhone SE and the like: the stacked cards don't fit with everything else.
    private var isShort: Bool { height < 740 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("SufficeMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                Text("Suffice")
                    .font(.system(size: 17, weight: .bold))
            }
            .padding(.top, isShort ? 12 : 28)

            WelcomeHero(isShort: isShort)
                .padding(.top, isShort ? 20 : 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Know you have enough.")
                    .font(.system(size: isShort ? 32 : 38, weight: .heavy))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("One budget for the two of you, the bills coming due, and what’s left, at a glance.")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(hex: 0xC7C7CC))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                if appleUserID.isEmpty {
                    // Optional, as in every Hearth app: one sign-in for all of them. Connecting a
                    // bank needs it; everything else works without it.
                    ProfileAppleButton()
                        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                        .clipShape(.capsule)
                    Button("Continue Without an Account") { flow.go(to: .household) }
                        .buttonStyle(.onboarding(.plain))
                } else {
                    Button("Get Started") { flow.go(to: .household) }
                        .buttonStyle(.onboarding())
                }
                Text(appleUserID.isEmpty
                     ? "Optional. One sign-in for every Hearth app, needed to connect a bank. Your budget lives in your own iCloud. No ads, no tracking."
                     : "Your budget lives in your own iCloud. No ads, no tracking.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(maxWidth: OnboardingStyle.columnWidth)
        .frame(maxWidth: .infinity)
        .background(OnboardingStyle.wash.ignoresSafeArea())
        // Signed in with Apple here: on to the household.
        .onChange(of: appleUserID) { _, id in
            if !id.isEmpty { flow.go(to: .household) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}

/// The sample month behind the promise: a left-to-spend card, with a budget and a bill tilted
/// under it like cards on a table.
private struct WelcomeHero: View {
    var isShort: Bool

    private var month: String { Date.now.formatted(.dateTime.month(.wide)) }

    private var daysLeft: Int {
        let calendar = Calendar.current
        let span = MonthSpan(containing: .now)
        return max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: span.end).day ?? 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: 0.62)
                        .stroke(.white, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 74, height: 74)
                .padding(6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Left to spend")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xA7E8B8))
                    Text("$1,284")
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(-0.5)
                    Text("\(daysLeft) \(daysLeft == 1 ? "day" : "days") to go in \(month)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0xC9D6CC))
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(.white.opacity(0.10), in: .rect(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.16)))

            if !isShort {
                sampleRow(symbol: "fork.knife", tint: Color(hex: 0x3A1F1F), ink: Color(hex: 0xFF8A8A),
                          title: "Groceries", detail: "$514 of $600", trailing: "$86 left", trailingColor: OnboardingStyle.accent)
                    .padding(.leading, 18)
                    .padding(.trailing, 30)
                    .rotationEffect(.degrees(-2))
                    .offset(y: 156)
                sampleRow(symbol: "house.fill", tint: Color(hex: 0x1E2A3D), ink: Color(hex: 0x7FB2FF),
                          title: "Rent", detail: "Due Friday · Autopay", trailing: "$1,850", trailingColor: .white)
                    .padding(.leading, 40)
                    .padding(.trailing, 6)
                    .rotationEffect(.degrees(1.5))
                    .offset(y: 236)
            }
        }
        .frame(height: isShort ? 128 : 316, alignment: .top)
    }

    private func sampleRow(symbol: String, tint: Color, ink: Color, title: String, detail: String, trailing: String, trailingColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 38, height: 38)
                .background(tint, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(OnboardingStyle.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(OnboardingStyle.card, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}
