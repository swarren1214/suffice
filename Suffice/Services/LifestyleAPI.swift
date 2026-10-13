import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security

actor LifestyleAPI {
    static let shared = LifestyleAPI()

    nonisolated struct Identity: Decodable, Sendable {
        let id: String
    }

    private nonisolated struct AuthUser: Codable, Sendable {
        let id: String
        let isAnonymous: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
        }
    }

    private nonisolated struct AuthSession: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int
        let user: AuthUser

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case user
        }
    }

    private nonisolated struct AuthError: Decodable {
        let msg: String?
        let message: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case msg, message
            case errorDescription = "error_description"
        }
    }

    /// An error from the Lifestyle API's `{ "error": { "code", "message" } }` contract.
    nonisolated struct APIFailure: LocalizedError, Sendable {
        let status: Int
        let code: String
        let message: String
        var errorDescription: String? { message }
        /// The bank wants the person to sign in again (Plaid update mode).
        var needsBankReauth: Bool { code == "CONNECTION_NEEDS_REAUTH" }
        /// Banking needs Sign in with Apple, not the anonymous session.
        var needsAppleSignIn: Bool { code == "REGISTERED_IDENTITY_REQUIRED" }
    }

    private nonisolated struct APIErrorEnvelope: Decodable {
        nonisolated struct Body: Decodable { let code: String; let message: String }
        let error: Body
    }

    nonisolated enum ClientError: LocalizedError {
        case invalidResponse
        case service(String)
        case missingAppleToken
        case missingAppleNonce

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The identity service returned an invalid response."
            case .service(let message): message
            case .missingAppleToken: "Apple did not provide an identity token. Please try again."
            case .missingAppleNonce: "The Apple sign-in request expired. Please try again."
            }
        }
    }

    private static let keychainService = "com.stephenwarren.lifestyle.supabase"
    private static let keychainAccount = "session"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lifestyle", category: "api")

    private let session: URLSession
    private var authSession: AuthSession?

    init(session: URLSession = .shared) {
        self.session = session
        authSession = Self.loadSession()
    }

    func prepareSession() async {
        do {
            _ = try await identity()
        } catch {
            Self.log.error("API session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func identity() async throws -> Identity {
        let data = try await authorizedData(path: "/v1/me")
        return try JSONDecoder().decode(Identity.self, from: data)
    }

    func createPlaidLinkToken() async throws -> Data {
        try await authorizedData(path: "/v1/banking/link-token", method: "POST", body: Data("{}".utf8))
    }

    /// True once the person has signed in with Apple (banking refuses anonymous sessions).
    var isSignedInWithApple: Bool {
        guard let authSession else { return false }
        return authSession.user.isAnonymous != true
    }

    /// Forgets the Supabase session (Profile › Erase). The next API call starts a new
    /// anonymous one.
    func signOut() {
        Self.deleteStoredSession()
        authSession = nil
    }

    // MARK: Banking

    /// A Plaid Link token: for a new bank, or (with itemID) to sign in to one again.
    func plaidLinkToken(itemID: String? = nil) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: itemID.map { ["itemId": $0] } ?? [String: String]())
        let data = try await authorizedData(path: "/v1/banking/link-token", method: "POST", body: body)
        return try Self.decode(LinkToken.self, from: data).linkToken
    }

    /// Finishes connecting a bank with Link's public token. The API keeps the access token.
    func connectBank(publicToken: String) async throws -> NewBankConnection {
        let body = try JSONSerialization.data(withJSONObject: ["publicToken": publicToken])
        let data = try await authorizedData(path: "/v1/banking/connections", method: "POST", body: body)
        return try Self.decode(NewBankConnection.self, from: data)
    }

    /// Changes since `cursor` (empty for the first sync). Call again while `hasMore`.
    func syncBank(itemID: String, cursor: String) async throws -> BankSyncPage {
        let body = try JSONSerialization.data(withJSONObject: cursor.isEmpty ? [String: String]() : ["cursor": cursor])
        let data = try await authorizedData(path: "/v1/banking/connections/\(itemID)/sync", method: "POST", body: body)
        return try Self.decode(BankSyncPage.self, from: data)
    }

    func disconnectBank(itemID: String) async throws {
        _ = try await authorizedData(path: "/v1/banking/connections/\(itemID)", method: "DELETE")
    }

    private nonisolated struct LinkToken: Decodable { let linkToken: String }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    func signInWithApple(identityToken: Data?, nonce: String?) async throws {
        guard let identityToken, let token = String(data: identityToken, encoding: .utf8) else {
            throw ClientError.missingAppleToken
        }
        guard let nonce else { throw ClientError.missingAppleNonce }
        let body = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": token,
            "nonce": nonce,
        ])
        let newSession: AuthSession = try await auth(path: "/auth/v1/token?grant_type=id_token", body: body)
        try store(newSession)
    }

    nonisolated static func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientError.service("Could not securely prepare Sign in with Apple.")
        }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let digest = SHA256.hash(data: Data(nonce.utf8))
        request.nonce = digest.map { String(format: "%02x", $0) }.joined()
        return nonce
    }

    private func authorizedData(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var current = try await validSession()
        var result = try await apiRequest(path: path, method: method, body: body, accessToken: current.accessToken)
        if result.response.statusCode == 401 {
            current = try await refresh(current.refreshToken)
            result = try await apiRequest(path: path, method: method, body: body, accessToken: current.accessToken)
        }
        guard (200..<300).contains(result.response.statusCode) else {
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: result.data) {
                throw APIFailure(status: result.response.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw Self.error(from: result.data, status: result.response.statusCode)
        }
        return result.data
    }

    private func apiRequest(path: String, method: String, body: Data?, accessToken: String) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: AppConfig.apiBaseURL) else { throw ClientError.invalidResponse }
        // Bank syncs page through Plaid and can take a while.
        var request = URLRequest(url: url, timeoutInterval: path.hasPrefix("/v1/banking") ? 60 : 15)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, response)
    }

    private func validSession() async throws -> AuthSession {
        if let authSession, authSession.expiresAt > Int(Date().timeIntervalSince1970) + 60 {
            return authSession
        }
        if let refreshToken = authSession?.refreshToken {
            do { return try await refresh(refreshToken) }
            catch {
                Self.deleteStoredSession()
                authSession = nil
            }
        }
        return try await signInAnonymously()
    }

    private func signInAnonymously() async throws -> AuthSession {
        let newSession: AuthSession = try await auth(path: "/auth/v1/signup", body: Data("{}".utf8))
        try store(newSession)
        return newSession
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let refreshed: AuthSession = try await auth(path: "/auth/v1/token?grant_type=refresh_token", body: body)
        try store(refreshed)
        return refreshed
    }

    private func auth<T: Decodable>(path: String, body: Data) async throws -> T {
        guard let url = URL(string: path, relativeTo: AppConfig.supabaseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(AppConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Self.error(from: data, status: response.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private func store(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ClientError.service("Could not securely save the API session.")
            }
        } else if updateStatus != errSecSuccess {
            throw ClientError.service("Could not securely update the API session.")
        }
        authSession = session
    }

    private nonisolated static func loadSession() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private nonisolated static func deleteStoredSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static func error(from data: Data, status: Int) -> ClientError {
        let detail = try? JSONDecoder().decode(AuthError.self, from: data)
        let message = detail?.message ?? detail?.msg ?? detail?.errorDescription
        return .service(message ?? "The service returned HTTP \(status).")
    }
}

// MARK: - Banking contract

nonisolated struct BankAccount: Decodable, Sendable {
    let id: String
    let name: String
    let mask: String
    /// checking, savings, credit or other.
    let kind: String
    let balanceCents: Int
}

nonisolated struct BankTransaction: Decodable, Sendable {
    let id: String
    let accountId: String
    /// yyyy-MM-dd
    let date: String
    let payee: String
    let amountCents: Int
    let isIncome: Bool
    let category: String?
    /// Plaid's merchant logo, when it has one.
    let logoUrl: String?
    /// The merchant's website domain ("target.com"), for Logo.dev.
    let merchantDomain: String?
    let city: String?
    let latitude: Double?
    let longitude: Double?
}

nonisolated struct NewBankConnection: Decodable, Sendable {
    let itemId: String
    let institution: String
    let accounts: [BankAccount]
}

nonisolated struct BankSyncPage: Decodable, Sendable {
    let added: [BankTransaction]
    let modified: [BankTransaction]
    let removed: [String]
    let accounts: [BankAccount]
    let nextCursor: String
    let hasMore: Bool
}
