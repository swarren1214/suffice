import SwiftUI

/// Welcome: the promise, a glimpse of the app (what's left to spend, a budget, a bill), and two
/// ways in: Get Started, or I Have an Invite for a partner joining an existing budget.
struct OnboardingWelcome: View {
    @Environment(OnboardingFlow.self) private var flow
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
                Button("Get Started") { flow.go(to: .household) }
                    .buttonStyle(.onboarding())
                Button {
                    flow.go(to: .invite)
                } label: {
                    Label("I Have an Invite", systemImage: "person.2.fill")
                }
                .buttonStyle(.onboarding(.secondary))
                Text("Your budget lives in your own iCloud. No ads, no tracking.")
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

/// I Have an Invite: how to open the invitation your partner sent, and joining once it's here.
/// The invitation arrives through the scene delegate (`HouseholdSync.receive`); joining
/// finishes onboarding, and the tabs ask which person you are.
struct OnboardingInvite: View {
    @Environment(OnboardingFlow.self) private var flow
    @State private var household = HouseholdSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button {
                household.pendingInvite = nil
                flow.back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: household.pendingInvite == nil ? "envelope.open.fill" : "person.2.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(
                            LinearGradient(colors: [Color(hex: 0x2CB855), Brand.greenDeep], startPoint: .top, endPoint: .bottom),
                            in: .rect(cornerRadius: 18, style: .continuous)
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(household.pendingInvite == nil ? "Join your partner’s budget" : "\(household.inviterName) invited you")
                            .font(.system(size: 32, weight: .heavy))
                            .tracking(-0.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(household.pendingInvite == nil
                             ? "Open the invitation on this \(DeviceName.current) and you’ll both see and edit the same budget."
                             : "Join to share one budget. You’ll both see every change, and each of you connects your own banks.")
                            .font(.system(size: 16))
                            .foregroundStyle(OnboardingStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if household.pendingInvite == nil {
                        OnboardingCard {
                            stepRow(1, "Ask for an invite", "In Suffice on their iPhone: Profile › Household › Invite to Household.")
                            OnboardingDivider(inset: 62)
                            stepRow(2, "Open the link here", "Tap the invitation they send you in Messages or Mail. Suffice opens right to it.")
                            OnboardingDivider(inset: 62)
                            stepRow(3, "Use the right Apple Account", "The one the invitation was sent to, signed in to iCloud on this \(DeviceName.current).")
                        }
                        HStack(spacing: 10) {
                            ProgressView().tint(OnboardingStyle.tertiaryText)
                            Text("Waiting for the invitation…")
                                .font(.system(size: 14))
                                .foregroundStyle(OnboardingStyle.tertiaryText)
                        }
                        .padding(.horizontal, 6)
                    } else {
                        if let error = household.joinError {
                            Label("Couldn’t join yet: \(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0xFF9F57))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Label("The starter budget on this \(DeviceName.current) is replaced by the shared one.", systemImage: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xC9DAF5))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: 0x7FB2FF).opacity(0.10), in: .rect(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0x7FB2FF).opacity(0.22)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 10) {
                if household.pendingInvite != nil {
                    Button(household.joinError == nil ? "Join \(household.inviterName)’s Household" : "Try Again") {
                        Task { await household.acceptInvite() }
                    }
                    .buttonStyle(.onboarding())
                    .disabled(household.isWorking)
                }
                Button(household.pendingInvite == nil ? "Set Up My Own Budget Instead" : "Not Now") {
                    household.pendingInvite = nil
                    flow.go(to: .household)
                }
                .buttonStyle(.onboarding(.plain))
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: OnboardingStyle.columnWidth)
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea())
        .animation(.smooth, value: household.pendingInvite != nil)
    }

    private func stepRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OnboardingStyle.accent)
                .frame(width: 32, height: 32)
                .background(OnboardingStyle.accent.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
