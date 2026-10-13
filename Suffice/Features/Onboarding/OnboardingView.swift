import AuthenticationServices
import SwiftData
import SwiftUI

/// First run: Welcome, Connect accounts, then who's in the household.
///
/// Signing in is optional. Everything works without it (App Review rejects apps that hold
/// features behind a sign-in they don't need); Sign in with Apple just fills in your name.
struct OnboardingView: View {
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @State private var step = 1
    @State private var givenName = ""

    var body: some View {
        Group {
            switch step {
            case 1:
                WelcomeView(givenName: $givenName) { withAnimation(.smooth) { step = 2 } }
            case 2:
                ConnectView(step: (2, 3)) { withAnimation(.smooth) { step = 3 } }
            default:
                HouseholdSetupView(givenName: givenName) { onboarded = true }
            }
        }
        .transition(.opacity)
    }
}

/// The sign-in screen, laid out like Hearken's: the app icon, name and promise, three things
/// Suffice does, and Sign in with Apple pinned at the bottom with "Not now" under it. Signing in
/// is optional (App Review guideline 5.1.1); it only fills in your name.
private struct WelcomeView: View {
    @Binding var givenName: String
    var next: () -> Void

    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @State private var signedIn = false
    @State private var errorMessage: String?

    init(givenName: Binding<String>, next: @escaping () -> Void) {
        self._givenName = givenName
        self.next = next
    }

    var body: some View {
        OnboardingPage(title: "Suffice", subtitle: "Budget together, and know you have enough.") { isShort in
            AppIconBadge(size: isShort ? 64 : 92)
        } content: { isShort in
            if signedIn {
                signedInConfirmation
            } else {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        OnboardingFeatureRow(symbol: "chart.pie.fill", title: "One budget for two", detail: "Plan each month together and see what's left at a glance.")
                        OnboardingFeatureRow(symbol: "calendar.badge.checkmark", title: "Bills on time", detail: "See what's due this week and mark it paid in a tap.")
                        OnboardingFeatureRow(symbol: "icloud.fill", title: "Private by design", detail: "Your budget lives in your own iCloud. No ads, no tracking, no servers.")
                    }
                    // Short screens: the fine print scrolls with the content so the pinned
                    // buttons don't cover the features.
                    if isShort { finePrint }
                }
            }
        } controls: { isShort in
            if signedIn {
                OnboardingPrimaryButton(title: "Continue", action: next)
            } else {
                VStack(spacing: 6) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                                appleUserID = credential.user
                                if let name = credential.fullName?.givenName, !name.isEmpty {
                                    givenName = name
                                }
                            }
                            withAnimation { signedIn = true }
                        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                            break // The person closed the sheet; nothing to report.
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                        }
                    }
                    .modifier(AdaptiveSignInStyle())
                    .frame(height: 52)
                    .clipShape(Capsule())

                    Button("Not now", action: next)
                        .frame(minHeight: 44)

                    if !isShort { finePrint }
                }
            }
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var signedInConfirmation: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Brand.green)
                .symbolEffect(.bounce, value: signedIn)
            Text(givenName.isEmpty ? "You're signed in" : "Welcome, \(givenName)")
                .font(.title2.bold())
            Text("Next, connect the accounts you budget from.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var finePrint: some View {
        Text("Optional. Signing in adds your name. Everything else works, and syncs with iCloud, without it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

/// The adaptive Sign in with Apple button style: black in light mode, white in dark mode.
private struct AdaptiveSignInStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    }
}

/// Step 3: who's budgeting. Creates the household members and marks this iPhone's person.
private struct HouseholdSetupView: View {
    var givenName: String
    var finish: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var myName = ""
    @State private var partnerName = ""
    @State private var myPhoto: Data?
    @State private var partnerPhoto: Data?
    /// Set once Start Budgeting runs, so a second tap (or Return) can't add everyone again.
    @State private var didSave = false
    @FocusState private var field: Field?

    private enum Field { case mine, partner }

    init(givenName: String, finish: @escaping () -> Void) {
        self.givenName = givenName
        self.finish = finish
    }

    private var canStart: Bool { !myName.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        OnboardingPage(
            title: "Who's budgeting?",
            subtitle: "Each of you gets a badge on the transactions you make. Tap a circle to add a photo.",
            step: (3, 3)
        ) { isShort in
            OnboardingSymbolIcon(symbol: "person.2.fill", size: isShort ? 64 : 92)
        } content: { _ in
            VStack(spacing: 0) {
                nameRow("Your name", text: $myName, photo: $myPhoto, color: .green, which: .mine)
                Divider().padding(.leading, 66)
                nameRow("Partner's name (optional)", text: $partnerName, photo: $partnerPhoto, color: .purple, which: .partner)
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        } controls: { _ in
            VStack(spacing: 6) {
                OnboardingPrimaryButton(title: "Start Budgeting", action: save)
                    .disabled(!canStart)
                Button("Skip for now", action: finish)
                    .frame(minHeight: 44)
            }
        }
        .onAppear {
            if myName.isEmpty { myName = givenName }
        }
    }

    /// A name field with the badge it will become: their photo, or their initial in their
    /// color. Tapping the badge picks a photo.
    private func nameRow(_ prompt: String, text: Binding<String>, photo: Binding<Data?>, color: MemberColor, which: Field) -> some View {
        HStack(spacing: 12) {
            PhotoPickerAvatar(name: text.wrappedValue, color: color, photo: photo, size: 40)
            TextField(prompt, text: text)
                .textContentType(which == .mine ? .givenName : nil)
                .textInputAutocapitalization(.words)
                .submitLabel(which == .mine ? .next : .done)
                .focused($field, equals: which)
                .onSubmit {
                    if which == .mine {
                        field = .partner
                    } else if canStart {
                        save()
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }

    private func save() {
        guard canStart, !didSave else { return }
        didSave = true
        let mine = person(named: myName, color: .green, photo: myPhoto, order: 0)
        let partner = partnerName.trimmingCharacters(in: .whitespaces)
        if !partner.isEmpty {
            _ = person(named: partner, color: .purple, photo: partnerPhoto, order: 1)
        }
        try? context.save()
        currentMember = mine.id.uuidString
        finish()
    }

    /// The household member with this name, updated, or a new one. Someone going through
    /// onboarding again (after erasing data, say) never ends up listed twice.
    private func person(named rawName: String, color: MemberColor, photo: Data?, order: Int) -> Member {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let existing = members.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() }) {
            if let photo { existing.photoData = photo }
            return existing
        }
        let start = (members.map(\.sortOrder).max() ?? -1) + 1
        let member = Member(name: name, color: color, photoData: photo, sortOrder: start + order)
        context.insert(member)
        return member
    }
}

#Preview {
    OnboardingView()
        .previewEnvironment()
}
