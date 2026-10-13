import Foundation
import LocalAuthentication
import Observation

/// Profile › Lock with Face ID. When it's on, the app covers itself whenever it goes to the
/// background and asks for Face ID (or the passcode) to come back.
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    private(set) var isAuthenticating = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.faceIDLock) }

    /// "Face ID", "Touch ID" or "Passcode", for labels.
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Called when the app leaves the foreground.
    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your budget")
            if ok { isLocked = false }
        } catch {
            // Stay locked; the lock screen offers to try again.
        }
    }

    /// Checks that this iPhone can authenticate before turning the lock on.
    func canLock() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
