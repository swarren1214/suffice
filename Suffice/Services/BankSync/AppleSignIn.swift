import AuthenticationServices
import UIKit

/// Sign in with Apple from anywhere (Connect a Bank, when someone skipped it in onboarding):
/// shows Apple's sheet with a nonce, then trades the identity token for a durable Supabase
/// session through HearthAPI, the same as onboarding's button.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var nonce: String?
    /// Keeps the request alive while Apple's sheet is up.
    private static var current: AppleSignIn?

    /// Signs in and remembers the Apple user. Throws `BankSyncError.cancelled` if they close it.
    static func signIn() async throws {
        let helper = AppleSignIn()
        current = helper
        defer { current = nil }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // The email too, so the Hearth account has the same one in every app.
        request.requestedScopes = [.fullName, .email]
        helper.nonce = try HearthAPI.prepareAppleRequest(request)
        let credential: ASAuthorizationAppleIDCredential = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            helper.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = helper
            controller.presentationContextProvider = helper
            controller.performRequests()
        }
        try await HearthAPI.shared.signInWithApple(
            identityToken: credential.identityToken,
            nonce: helper.nonce,
            appleUserID: credential.user,
            fullName: credential.fullName,
            email: credential.email
        )
        UserDefaults.standard.set(credential.user, forKey: SettingsKey.appleUserID)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            finish(.success(credential))
        } else {
            finish(.failure(HearthAPI.ClientError.missingAppleToken))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            finish(.failure(BankSyncError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window = UIApplication.shared.foregroundWindow { return window }
        // Sign in is only offered from a screen on display, so there's always a scene.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            preconditionFailure("Sign in with Apple needs a window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
    }

    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension UIApplication {
    /// The foreground window people are looking at.
    var foregroundWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return (active + scenes).flatMap(\.windows).first(where: \.isKeyWindow) ?? (active + scenes).first?.windows.first
    }

    /// The view controller on top, to present Plaid Link from.
    var topViewController: UIViewController? {
        var top = foregroundWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
