import Foundation
import OSLog
import SwiftData

/// Connecting banks through Plaid and bringing their transactions in, via the Lifestyle API.
///
/// Connect: Sign in with Apple if needed → link token → Plaid Link → the API exchanges and keeps
/// the access token → the bank's accounts appear on Overview (source Plaid) → first sync.
/// Sync: the API returns what's new, changed and removed since the bank's cursor, plus balances.
/// New transactions land in Activity › New, with a category when a payee rule knows the
/// merchant. Transactions only live here and in iCloud; the API never stores them.
@MainActor
enum BankSync {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "bank-sync")

    // MARK: Connect

    /// Walks someone through connecting a bank. Throws `.cancelled` if they back out.
    @discardableResult
    static func connect(memberID: UUID?, in context: ModelContext) async throws -> LinkedBank {
        if !(await LifestyleAPI.shared.isSignedInWithApple) {
            try await AppleSignIn.signIn()
        }
        let linkToken = try await withAppleRetry { try await LifestyleAPI.shared.plaidLinkToken() }
        let link = try await PlaidLink.open(linkToken: linkToken)
        let connection = try await LifestyleAPI.shared.connectBank(publicToken: link.publicToken)

        let bank = existingBank(itemID: connection.itemId, in: context) ?? {
            let bank = LinkedBank(
                itemID: connection.itemId,
                institution: connection.institution,
                connectedByAppleID: UserDefaults.standard.string(forKey: SettingsKey.appleUserID) ?? ""
            )
            context.insert(bank)
            return bank
        }()
        upsertAccounts(connection.accounts, for: bank, in: context)
        try? context.save()

        try await sync(bank, memberID: memberID, in: context)
        return bank
    }

    /// For a bank that needs signing in again: Link in update mode, then a sync.
    static func reconnect(_ bank: LinkedBank, memberID: UUID?, in context: ModelContext) async throws {
        let linkToken = try await withAppleRetry { try await LifestyleAPI.shared.plaidLinkToken(itemID: bank.itemID) }
        _ = try await PlaidLink.open(linkToken: linkToken)
        // A successful sync clears needsReconnect.
        try await sync(bank, memberID: memberID, in: context)
    }

    /// Stops syncing a bank. Its accounts become manual and keep their transactions.
    static func disconnect(_ bank: LinkedBank, in context: ModelContext) async throws {
        do {
            try await LifestyleAPI.shared.disconnectBank(itemID: bank.itemID)
        } catch let failure as LifestyleAPI.APIFailure where failure.code == "CONNECTION_NOT_FOUND" {
            // Already gone on the API; forget it here too.
        }
        let itemID: String? = bank.itemID
        let accounts = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.plaidItemID == itemID }))) ?? []
        for account in accounts {
            account.sourceRaw = AccountSource.manual.rawValue
            account.balanceDate = .now
            account.plaidItemID = nil
            account.plaidAccountID = nil
        }
        context.delete(bank)
        try? context.save()
    }

    // MARK: Sync

    /// Brings one bank up to date, page by page.
    static func sync(_ bank: LinkedBank, memberID: UUID?, in context: ModelContext) async throws {
        var page: BankSyncPage
        repeat {
            do {
                page = try await LifestyleAPI.shared.syncBank(itemID: bank.itemID, cursor: bank.cursor)
            } catch let failure as LifestyleAPI.APIFailure where failure.needsBankReauth {
                bank.needsReconnect = true
                try? context.save()
                throw failure
            }
            apply(page, to: bank, memberID: memberID, in: context)
        } while page.hasMore
        log.info("Synced \(bank.institution, privacy: .public)")
    }

    /// Every bank this person connected. Failures are logged and skipped so one bank can't stop
    /// the rest; banks needing a new sign-in are marked.
    static func syncAll(memberID: UUID?, in context: ModelContext) async {
        guard await LifestyleAPI.shared.isSignedInWithApple else { return }
        let me = UserDefaults.standard.string(forKey: SettingsKey.appleUserID) ?? ""
        let banks = ((try? context.fetch(FetchDescriptor<LinkedBank>())) ?? [])
            .filter { $0.connectedByAppleID.isEmpty || $0.connectedByAppleID == me }
        for bank in banks where !bank.needsReconnect {
            do {
                try await sync(bank, memberID: memberID, in: context)
            } catch {
                log.error("Sync failed for \(bank.institution, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// On opening the app: sync when it's been more than an hour.
    static func syncAllIfStale(memberID: UUID?, in context: ModelContext) async {
        let banks = (try? context.fetch(FetchDescriptor<LinkedBank>())) ?? []
        guard banks.contains(where: { ($0.lastSynced ?? .distantPast) < Date.now.addingTimeInterval(-3600) }) else { return }
        await syncAll(memberID: memberID, in: context)
    }

    // MARK: Applying changes

    private static func apply(_ page: BankSyncPage, to bank: LinkedBank, memberID: UUID?, in context: ModelContext) {
        upsertAccounts(page.accounts, for: bank, in: context)
        let accountIDs = Dictionary(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? []).compactMap { account in
                account.plaidAccountID.map { ($0, account.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID != nil }))) ?? []).compactMap { entry in
                entry.externalID.map { ($0, entry) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for transaction in page.added where existing[transaction.id] == nil {
            let entry = LedgerEntry(
                date: day(transaction.date),
                payee: transaction.payee,
                amountCents: transaction.amountCents,
                kind: transaction.isIncome ? .income : .expense,
                categoryID: transaction.isIncome ? nil : Ledger.ruleCategory(for: transaction.payee, in: context),
                memberID: memberID,
                accountID: accountIDs[transaction.accountId],
                isReviewed: false
            )
            entry.externalID = transaction.id
            entry.logoURL = MerchantLogo.url(plaidLogo: transaction.logoUrl, domain: transaction.merchantDomain)?.absoluteString
            entry.placeName = transaction.city
            entry.latitude = transaction.latitude
            entry.longitude = transaction.longitude
            context.insert(entry)
            existing[transaction.id] = entry
        }

        // Changes from the bank (a tip added, a merchant renamed). People's own edits to the
        // category, person and note stay.
        for transaction in page.modified {
            guard let entry = existing[transaction.id] else { continue }
            entry.date = day(transaction.date)
            entry.payee = transaction.payee
            entry.amountCents = transaction.amountCents
            entry.kind = transaction.isIncome ? .income : .expense
            entry.logoURL = MerchantLogo.url(plaidLogo: transaction.logoUrl, domain: transaction.merchantDomain)?.absoluteString ?? entry.logoURL
        }

        for id in page.removed {
            if let entry = existing[id] { context.delete(entry) }
        }

        bank.cursor = page.nextCursor
        bank.lastSynced = .now
        bank.needsReconnect = false
        try? context.save()
    }

    /// Retries once after Sign in with Apple when the API says banking needs it.
    private static func withAppleRetry<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let failure as LifestyleAPI.APIFailure where failure.needsAppleSignIn {
            try await AppleSignIn.signIn()
            return try await call()
        }
    }

    private static func existingBank(itemID: String, in context: ModelContext) -> LinkedBank? {
        try? context.fetch(FetchDescriptor<LinkedBank>(predicate: #Predicate { $0.itemID == itemID })).first
    }

    /// Adds the bank's accounts to Overview, or refreshes their balances.
    private static func upsertAccounts(_ accounts: [BankAccount], for bank: LinkedBank, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        var nextOrder = (all.map(\.sortOrder).max() ?? -1) + 1
        for remote in accounts {
            let kind: AccountKind = switch remote.kind {
            case "savings": .savings
            case "credit": .credit
            default: .checking
            }
            let account: Account
            if let match = all.first(where: { $0.plaidAccountID == remote.id }) {
                account = match
            } else if !remote.mask.isEmpty, let earlier = all.first(where: {
                // The same account from before a disconnect: pick it back up instead of adding a copy.
                $0.plaidAccountID == nil && $0.source == .manual && $0.institution == bank.institution && $0.mask == remote.mask
            }) {
                account = earlier
                account.sourceRaw = AccountSource.plaid.rawValue
                account.plaidItemID = bank.itemID
                account.plaidAccountID = remote.id
            } else {
                account = Account(institution: bank.institution, name: remote.name, mask: remote.mask, kind: kind, source: .plaid, balanceCents: 0, sortOrder: nextOrder)
                account.plaidItemID = bank.itemID
                account.plaidAccountID = remote.id
                context.insert(account)
                nextOrder += 1
            }
            account.balanceCents = remote.balanceCents
            account.balanceDate = .now
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The bank's date, at noon so it stays on that day in nearby time zones.
    private static func day(_ text: String) -> Date {
        let date = dayFormatter.date(from: text) ?? .now
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }
}

/// Merchant logos: Plaid's when the bank feed has one, otherwise Logo.dev by the merchant's
/// domain, straight from its CDN with Suffice's publishable key (no API round trip).
enum MerchantLogo {
    static func url(plaidLogo: String?, domain: String?) -> URL? {
        if let plaidLogo, let url = URL(string: plaidLogo), url.scheme == "https" { return url }
        guard let domain, !domain.isEmpty, !AppConfig.logoDevPublishableKey.isEmpty,
              var components = URLComponents(string: "https://img.logo.dev/\(domain)") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "token", value: AppConfig.logoDevPublishableKey),
            URLQueryItem(name: "size", value: "128"),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "fallback", value: "404"),
        ]
        return components.url
    }
}
