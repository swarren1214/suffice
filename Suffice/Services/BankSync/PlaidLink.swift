import LinkKit
import UIKit

/// Opens Plaid Link (LinkKit 7), where people pick their bank and sign in to it. Bank
/// credentials stay inside Link; Suffice only gets a short-lived public token back.
@MainActor
enum PlaidLink {
    nonisolated struct Success: Sendable {
        var publicToken: String
        var institution: String
    }

    /// Keeps Link's session alive while it's on screen.
    private static var current: Run?

    /// Shows Link for a link token from the API. Throws `.cancelled` when the person closes it.
    static func open(linkToken: String) async throws -> Success {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Success, Error>) in
            let run = Run(continuation: continuation)
            // LinkKit's callbacks aren't main-actor isolated, so pull out the values there and
            // hop back to the main actor to finish.
            let configuration = LinkTokenConfiguration(
                token: linkToken,
                onSuccess: { success in
                    let result = Success(publicToken: success.publicToken, institution: success.metadata.institution.name)
                    Task { @MainActor in run.finish(.success(result)) }
                },
                onExit: { exit in
                    // Plaid's display message is written for people; its error message is for
                    // developers, so it never shows.
                    let failed = exit.error != nil
                    let message = exit.error.flatMap(\.displayMessage)
                    Task { @MainActor in
                        if failed {
                            run.finish(.failure(BankSyncError.link(message ?? "Your bank couldn’t be connected just now. Try again in a moment.")))
                        } else {
                            run.finish(.failure(BankSyncError.cancelled))
                        }
                    }
                },
                onEvent: nil,
                onLoad: nil
            )
            do {
                let session = try Plaid.createPlaidLinkSession(configuration: configuration)
                guard let presenter = UIApplication.shared.topViewController else {
                    run.finish(.failure(BankSyncError.link("Couldn't open Plaid right now. Try again.")))
                    return
                }
                run.session = session
                current = run
                session.open(using: .viewController(presenter))
            } catch {
                run.finish(.failure(BankSyncError.link("Couldn't open Plaid right now. Try again.")))
            }
        }
    }

    /// One trip through Link: resumes the caller exactly once.
    private final class Run {
        private var continuation: CheckedContinuation<Success, Error>?
        var session: PlaidLinkSession?

        init(continuation: CheckedContinuation<Success, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Success, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            session = nil
            if PlaidLink.current === self { PlaidLink.current = nil }
            continuation.resume(with: result)
        }
    }
}

enum BankSyncError: LocalizedError {
    case cancelled
    case link(String)
    /// Connecting and syncing banks need Suffice Plus or Hearth+: show the paywall.
    case needsPlan

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .link(let message): message
        case .needsPlan: "Automatic bank sync comes with Suffice Plus or Hearth+."
        }
    }
}
