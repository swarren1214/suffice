import CloudKit
import Foundation

/// The words an alert or a line on screen shows when something fails: what didn't work and what
/// to do next, never a raw error, status code or server text. Log the raw error separately.
///
///     } catch {
///         log.error("Connecting a bank failed: \(error.localizedDescription, privacy: .public)")
///         problem = FriendlyError.message(for: error, fallback: "Suffice couldn’t connect your bank. Try again in a moment.")
///     }
///
/// `fallback` is the action's own sentence, used whenever the error itself has nothing better to
/// say. Messages Suffice already writes for people (its own errors, mapped server codes) pass
/// through as they are.
nonisolated enum FriendlyError {
    static func message(for error: any Error, fallback: String) -> String {
        // Suffice's own errors, already written for people.
        if let error = error as? ReceiptSplitter.Failure { return error.errorDescription ?? fallback }
        if let error = error as? DocumentReader.Failure { return error.errorDescription ?? fallback }
        if let error = error as? BankSyncError { return error.errorDescription ?? fallback }
        if let error = error as? MailAccounts.Failure {
            if case .rejected = error { return "Your email provider didn’t finish signing in. Try connecting again." }
            return error.errorDescription ?? fallback
        }
        if let error = error as? MailClient.Failure {
            switch error {
            case .http(let status) where status == 401 || status == 403:
                return "Suffice needs you to connect your email again."
            case .http:
                return "Your mailbox didn’t answer. Try again in a bit."
            }
        }

        // The Hearth API.
        if let failure = error as? HearthAPI.APIFailure {
            if failure.code == "SIGNED_OUT" { return failure.message }
            switch failure.status {
            case 401: return "Your sign-in has expired. Sign in with Apple again in Profile, then try again."
            case 402: return "That comes with Suffice Plus or Hearth+."
            case 429: return "Suffice is busy just now. Try again in a minute."
            case 500...: return "Suffice’s server is having trouble right now. Try again in a few minutes."
            default:
                // The API writes its 4xx messages for people.
                let message = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? fallback : message
            }
        }
        if let error = error as? HearthAPI.ClientError {
            switch error {
            case .rateLimited, .missingAppleToken, .missingAppleNonce:
                return error.errorDescription ?? fallback
            case .invalidResponse, .service, .rejected:
                return fallback
            }
        }

        // The network.
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You’re offline. Connect to the internet and try again."
            case .timedOut:
                return "That took too long. Check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse:
                return "Suffice couldn’t reach its server. Try again in a few minutes."
            default:
                return fallback
            }
        }

        // iCloud.
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings, then try again."
            case .quotaExceeded: return "Your iCloud storage is full. Free up space in Settings › your name › iCloud, then try again."
            case .networkUnavailable, .networkFailure: return "You’re offline. Connect to the internet and try again."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "iCloud is busy just now. Try again in a minute."
            default: return fallback
            }
        }

        if error is DecodingError {
            return "Suffice got an answer it didn’t understand. Try again, and if it keeps happening, email support@hearthapps.com."
        }
        return fallback
    }
}
