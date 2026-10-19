import CryptoKit
import Foundation
import Observation
import OSLog
import Security

/// The mailboxes Suffice can read receipts and bills from, with read-only access.
nonisolated enum MailProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gmail, outlook

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        }
    }

    /// The OAuth client registered for Suffice (AppConfig). Empty until it's set up, and then
    /// Connect is off.
    var clientID: String {
        switch self {
        case .gmail: AppConfig.googleClientID
        case .outlook: AppConfig.microsoftClientID
        }
    }

    var isConfigured: Bool { !clientID.isEmpty }

    var authorizeURL: URL {
        switch self {
        case .gmail: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .outlook: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .gmail: URL(string: "https://oauth2.googleapis.com/token")!
        case .outlook: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// Read-only mail access, plus a refresh token.
    var scope: String {
        switch self {
        case .gmail: "https://www.googleapis.com/auth/gmail.readonly"
        case .outlook: "offline_access https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read"
        }
    }

    /// The app's own URL scheme the sign-in page returns to. Google's is the iOS client ID
    /// reversed; Microsoft's is the msauth scheme registered for the bundle ID.
    var callbackScheme: String {
        switch self {
        case .gmail:
            let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(prefix)"
        case .outlook:
            return "msauth.com.stephenwarren.suffice"
        }
    }

    var redirectURI: String {
        switch self {
        case .gmail: "\(callbackScheme):/oauth2redirect"
        case .outlook: "\(callbackScheme)://auth"
        }
    }
}

/// A connected mailbox's tokens, kept in the Keychain on this device only.
nonisolated struct MailTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// The address, for "Connected as …".
    var address: String
}

/// Connecting and disconnecting mailboxes, and fresh access tokens for reading them. The sign-in
/// is OAuth with PKCE in the system's web sheet (Suffice never sees a password); tokens stay in
/// this device's Keychain and never sync.
@Observable
final class MailAccounts {
    static let shared = MailAccounts()

    nonisolated enum Failure: LocalizedError, Sendable {
        case notConfigured
        case cancelled
        case rejected(String)
        /// The token endpoint said no for good (revoked or expired): connect again.
        case revoked
        case signedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured: "This build of Suffice isn’t set up to connect to that mailbox yet."
            case .cancelled: "Connecting was cancelled."
            case .rejected(let message): message
            case .revoked: "Suffice needs you to connect your email again."
            case .signedOut: "Suffice needs you to connect your email again."
            }
        }
    }

    /// The address each connected mailbox signed in as.
    private(set) var connected: [MailProvider: String] = [:]

    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "mail")

    private init() {
        for provider in MailProvider.allCases {
            if let tokens = Keychain.tokens(for: provider) { connected[provider] = tokens.address }
        }
    }

    var isConnected: Bool { !connected.isEmpty }

    // MARK: Connecting

    /// A sign-in to start: the page to open, and what to keep for finishing it.
    struct Request: Sendable {
        var provider: MailProvider
        var url: URL
        var verifier: String
        var state: String
    }

    func request(for provider: MailProvider) throws -> Request {
        guard provider.isConfigured else { throw Failure.notConfigured }
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if provider == .gmail {
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = items
        return Request(provider: provider, url: components.url!, verifier: verifier, state: state)
    }

    /// Finishes a sign-in from the page's answer: trades the code for tokens and saves them.
    func finish(_ request: Request, callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? Failure.cancelled : Failure.rejected("The sign-in didn’t work (\(error)).")
        }
        guard items.first(where: { $0.name == "state" })?.value == request.state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw Failure.rejected("The sign-in didn’t come back as expected. Try again.") }

        var tokens = try await Self.tokenRequest(request.provider, form: [
            "client_id": request.provider.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": request.provider.redirectURI,
            "code_verifier": request.verifier,
            "scope": request.provider.scope,
        ], keeping: nil)
        tokens.address = (try? await MailClient.address(of: request.provider, accessToken: tokens.accessToken)) ?? request.provider.name
        Keychain.save(tokens, for: request.provider)
        connected[request.provider] = tokens.address
        log.info("Connected \(request.provider.rawValue, privacy: .public)")
    }

    /// Forgets a mailbox: its tokens leave the Keychain. (Receipts already attached stay.)
    func disconnect(_ provider: MailProvider) {
        Keychain.delete(provider)
        connected[provider] = nil
        // Connecting again reads back the full look-back period.
        UserDefaults.standard.removeObject(forKey: EmailSettingsKey.lastScan(provider))
    }

    // MARK: Tokens

    /// A current access token, refreshed when it's about to expire.
    func accessToken(for provider: MailProvider) async throws -> String {
        guard var tokens = Keychain.tokens(for: provider) else { throw Failure.signedOut }
        if tokens.expiresAt > .now.addingTimeInterval(60) { return tokens.accessToken }
        do {
            let fresh = try await Self.tokenRequest(provider, form: [
                "client_id": provider.clientID,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "scope": provider.scope,
            ], keeping: tokens.refreshToken)
            tokens.accessToken = fresh.accessToken
            tokens.refreshToken = fresh.refreshToken
            tokens.expiresAt = fresh.expiresAt
            Keychain.save(tokens, for: provider)
            return tokens.accessToken
        } catch Failure.revoked {
            // The refresh token was revoked or expired: connecting again is the only way back.
            // (Anything else, like the server being busy, is tried again next time.)
            disconnect(provider)
            throw Failure.signedOut
        }
    }

    private nonisolated static func tokenRequest(_ provider: MailProvider, form: [String: String], keeping refreshToken: String?) async throws -> MailTokens {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in a form is a space; URLComponents leaves it alone, so encode it.
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        nonisolated struct Answer: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var error: String?
            var error_description: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw Failure.rejected("The mailbox didn’t answer as expected. Try again in a bit.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = answer.access_token else {
            if answer.error == "invalid_grant" || answer.error == "interaction_required" { throw Failure.revoked }
            throw Failure.rejected(answer.error_description ?? answer.error ?? "The mailbox didn’t accept the sign-in.")
        }
        guard let refresh = answer.refresh_token ?? refreshToken else {
            throw Failure.rejected("The mailbox didn’t allow staying connected. Try again.")
        }
        return MailTokens(accessToken: access, refreshToken: refresh, expiresAt: .now.addingTimeInterval(answer.expires_in ?? 3_600), address: "")
    }

    // MARK: PKCE

    private nonisolated static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

/// Mail tokens in the Keychain: this device only, readable after the first unlock (so a scan
/// can run when the app wakes in the background).
private nonisolated enum Keychain {
    static let service = "com.stephenwarren.suffice.mail"

    static func tokens(for provider: MailProvider) -> MailTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MailTokens.self, from: data)
    }

    static func save(_ tokens: MailTokens, for provider: MailProvider) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ provider: MailProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
