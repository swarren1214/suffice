import SwiftUI
import UIKit

/// Shows the lock cover in a window above everything, sheets included.
enum LockWindow {
    private static var window: UIWindow?

    static func show(lock: AppLock) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.rootViewController = UIHostingController(rootView: LockView().environment(lock))
        cover.windowLevel = .alert + 1
        cover.makeKeyAndVisible()
        window = cover
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// The cover shown while the budget is locked (Profile › Lock with Face ID), in the same style
/// as the sign-in screen.
struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            AppIconBadge(size: 92)
            Text("Suffice is locked")
                .font(.largeTitle.bold())
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Text("Unlock to see your budget.")
                .foregroundStyle(.secondary)
            Spacer()
            OnboardingPrimaryButton(title: "Unlock with \(lock.biometryName)", systemImage: "faceid") {
                Task { await lock.unlock() }
            }
            .disabled(lock.isAuthenticating)
            .frame(maxWidth: 460)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .tint(Brand.green)
        .task { await lock.unlock() }
    }
}
