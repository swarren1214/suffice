import AuthenticationServices
import SwiftData
import SwiftUI

/// Step 1, Who's budgeting: Continue with Apple (optional; it fills in your name and banks need
/// it), your name and your partner's with photos, and Caloma's family when it's on this iPhone.
struct OnboardingHousehold: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @AppStorage(CalomaFamily.dismissedKey) private var calomaDismissed = false
    @State private var calomaParents: [String] = []
    @State private var calomaHasPhotos = false
    @State private var appleNonce: String?
    @State private var signInError: String?
    @FocusState private var field: Field?

    private enum Field { case mine, partner }

    private var canContinue: Bool { !flow.myName.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        @Bindable var flow = flow
        OnboardingStep(
            title: "Who’s budgeting?",
            subtitle: "Each of you gets a badge on what you spend. Tap a circle to add a photo."
        ) {
            appleCard
            OnboardingCard {
                nameRow(label: "You", prompt: "Your name", text: $flow.myName, photo: $flow.myPhoto, color: .green, which: .mine)
                OnboardingDivider(inset: 82)
                nameRow(label: "Partner", prompt: "Their name (optional)", text: $flow.partnerName, photo: $flow.partnerPhoto, color: .purple, which: .partner)
            }
            if let suggestion = calomaSuggestion {
                calomaBanner(suggestion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } controls: {
            Button("Continue", action: save)
                .buttonStyle(.onboarding())
                .disabled(!canContinue)
        }
        .animation(.smooth, value: calomaSuggestion == nil)
        .onAppear {
            calomaParents = CalomaFamily.parentNames()
            calomaHasPhotos = calomaParents.prefix(2).contains { CalomaFamily.parentPhoto(named: $0) != nil }
            if flow.myName.isEmpty, let me = members.first(where: { $0.id.uuidString == currentMember }) {
                // Onboarding again (after erasing, say): start from who's already here.
                flow.myName = me.name
                flow.myPhoto = me.photoData
                flow.myID = me.id
            }
        }
        .alert("Couldn’t sign in", isPresented: Binding(get: { signInError != nil }, set: { if !$0 { signInError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signInError ?? "")
        }
    }

    // MARK: Sign in with Apple

    @ViewBuilder
    private var appleCard: some View {
        VStack(spacing: 12) {
            if appleUserID.isEmpty {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                    do {
                        appleNonce = try HearthAPI.prepareAppleRequest(request)
                    } catch {
                        signInError = error.localizedDescription
                    }
                } onCompletion: { result in
                    signedIn(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(Capsule())
                Text("Fills in your name, and you’ll need it to connect a bank. Optional.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: .circle)
                    Text("Signed in with Apple")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(OnboardingStyle.accent)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(OnboardingStyle.card, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func signedIn(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                signInError = "Apple did not return a usable credential. Please try again."
                return
            }
            let token = credential.identityToken
            let nonce = appleNonce
            let userID = credential.user
            let fullName = credential.fullName
            let email = credential.email
            Task { @MainActor in
                do {
                    try await HearthAPI.shared.signInWithApple(identityToken: token, nonce: nonce, appleUserID: userID, fullName: fullName, email: email)
                    withAnimation { appleUserID = userID }
                    // Apple only sends the name the first time; another Hearth app may have kept it.
                    let shared = HearthAPI.sharedAppleName(for: userID)?.split(separator: " ").first.map(String.init)
                    if flow.myName.trimmingCharacters(in: .whitespaces).isEmpty, let name = fullName?.givenName ?? shared, !name.isEmpty {
                        flow.myName = name
                    }
                } catch {
                    signInError = error.localizedDescription
                }
            }
        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            break
        case .failure(let error):
            signInError = error.localizedDescription
        }
    }

    // MARK: Names

    private func nameRow(label: String, prompt: String, text: Binding<String>, photo: Binding<Data?>, color: MemberColor, which: Field) -> some View {
        let isEmpty = text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 14) {
            PhotoPickerAvatar(name: isEmpty && which == .partner ? "+" : text.wrappedValue, color: color, photo: photo, size: 52)
                .overlay {
                    if isEmpty, photo.wrappedValue == nil, which == .partner {
                        Circle().strokeBorder(Color(hex: 0xC4A0FF).opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .accessibilityLabel(which == .mine ? "Add your photo" : "Add your partner’s photo")
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                TextField(prompt, text: text, prompt: Text(prompt).foregroundStyle(Color(hex: 0x7C7C82)))
                    .font(.system(size: 17))
                    .textContentType(which == .mine ? .givenName : nil)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(which == .mine ? .next : .done)
                    .focused($field, equals: which)
                    .onSubmit {
                        if which == .mine { field = .partner } else if canContinue { save() }
                    }
            }
            if which == .mine {
                Text("This \(DeviceName.current)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingStyle.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Caloma

    /// Your name and your partner's from Caloma's parents, when that would fill something in.
    private var calomaSuggestion: (mine: String, partner: String?)? {
        guard !calomaDismissed, !calomaParents.isEmpty, flow.partner == nil else { return nil }
        let typed = flow.myName.trimmingCharacters(in: .whitespaces)
        let mine: String
        if typed.isEmpty {
            mine = calomaParents[0]
        } else if let match = calomaParents.first(where: { $0.lowercased() == typed.lowercased() }) {
            mine = match
        } else {
            return nil
        }
        let partner = calomaParents.first { $0.lowercased() != mine.lowercased() }
        if partner == nil && !typed.isEmpty { return nil }
        return (mine, partner)
    }

    private func calomaBanner(_ suggestion: (mine: String, partner: String?)) -> some View {
        let names = ([suggestion.mine] + (suggestion.partner.map { [$0] } ?? [])).formatted(.list(type: .and))
        let pink = Color(hex: 0xFF6F8E)
        return HStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(hex: 0xE0284F), in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Caloma knows your family")
                    .font(.system(size: 14, weight: .semibold))
                Text(names + (calomaHasPhotos ? ", photos included" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xC7A8B2))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Use") { useCaloma(suggestion) }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0x2B0710))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(pink, in: .capsule)
                .buttonStyle(.plain)
            Button {
                withAnimation { calomaDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0xC7A8B2))
                    .frame(width: 28, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(hex: 0xE0284F).opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(pink.opacity(0.25)))
    }

    private func useCaloma(_ suggestion: (mine: String, partner: String?)) {
        withAnimation {
            flow.myName = suggestion.mine
            if flow.myPhoto == nil { flow.myPhoto = CalomaFamily.parentPhoto(named: suggestion.mine) }
            if let partner = suggestion.partner {
                flow.partnerName = partner
                if flow.partnerPhoto == nil { flow.partnerPhoto = CalomaFamily.parentPhoto(named: partner) }
            }
        }
    }

    // MARK: Saving

    /// Saves both people (renaming the ones saved earlier, if you came back) and marks you as
    /// this iPhone's person.
    private func save() {
        guard canContinue else { return }
        field = nil
        let me = upsert(id: flow.myID, name: flow.myName, color: .green, photo: flow.myPhoto, order: 0)
        flow.myID = me.id
        if let partner = flow.partner {
            flow.partnerID = upsert(id: flow.partnerID, name: partner, color: .purple, photo: flow.partnerPhoto, order: 1, excluding: me.id).id
        } else if let id = flow.partnerID, let saved = members.first(where: { $0.id == id }) {
            // The partner was cleared after coming back.
            context.delete(saved)
            flow.partnerID = nil
        }
        try? context.save()
        currentMember = me.id.uuidString
        flow.next()
    }

    /// The person saved earlier (by ID), else one with this name, updated; or a new one.
    private func upsert(id: UUID?, name rawName: String, color: MemberColor, photo: Data?, order: Int, excluding other: UUID? = nil) -> Member {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let existing = members.first { $0.id == id && $0.id != other }
            ?? members.first { $0.id != other && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() }
        if let existing {
            existing.name = name
            if let photo { existing.photoData = photo }
            return existing
        }
        let start = (members.map(\.sortOrder).max() ?? -1) + 1
        let member = Member(name: name, color: color, photoData: photo, sortOrder: start + order)
        context.insert(member)
        return member
    }
}
