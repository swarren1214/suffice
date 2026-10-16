import CloudKit
import OSLog
import SwiftData
import UIKit

/// Household sync: the budget in iCloud, shared between two Apple Accounts.
///
/// Everything lives in a record zone named "Household". The person who shares it (the owner)
/// keeps it in their private database; whoever accepts the invite (a member) sees the same zone
/// in their shared database, and both read and write it. Each person's own devices sync the
/// same way, so one mechanism covers "my iPhone and iPad" and "my wife's iPhone".
///
/// - Sending: SwiftData's history says what changed locally since the last look (inserts,
///   updates, and deletions with the deleted record's ID). Those become pending changes on a
///   CKSyncEngine, which uploads them when it can, retrying on its own.
/// - Receiving: the engine fetches what changed in the zone and they're applied to the store
///   under the author `syncAuthor`, so they aren't sent back.
/// - Conflicts: the last device to save wins, field by field from that device's copy.
/// - Joining replaces the budget on this device with the household's; the member's own budget
///   stays in their private iCloud and comes back if they leave.
@MainActor
@Observable
final class HouseholdSync: NSObject, CKSyncEngineDelegate {
    static let shared = HouseholdSync()
    static let zoneName = "Household"
    /// Marks the store changes that came from iCloud, so they aren't uploaded again.
    nonisolated static let syncAuthor = "household-sync"

    enum Role: Equatable {
        /// Syncs in this person's own iCloud (alone, or sharing it with someone).
        case owner
        /// Syncs in someone else's shared household. `ownerName` is their CloudKit user record.
        case member(ownerName: String)
    }

    enum AccountState: Equatable {
        case checking, available, noAccount, restricted, unavailable
    }

    private(set) var role: Role
    private(set) var account: AccountState = .checking
    /// The household's share: the owner's once they've shared it, or, for a member, the one
    /// they joined (for who shared it and who else is in).
    private(set) var share: CKShare?
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    /// The last problem in words for the iCloud Sync card, or nil when there's nothing to act on
    /// (offline, signed out: the card shows those itself). Cleared when a sync succeeds.
    private(set) var syncProblem: String?
    /// Changes queued on either engine that haven't gone up yet.
    private(set) var pendingChanges: Int?
    /// Why the last try at joining a household failed, for the invite screen.
    private(set) var joinError: String?
    /// An invitation waiting for the person to say yes (see AppRoot's alert).
    var pendingInvite: CKShare.Metadata?
    private(set) var isWorking = false

    let container = CKContainer(identifier: AppConfig.cloudKitContainerID)

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored private var historyToken: DefaultHistoryToken?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var fieldsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// History read up to here; written to disk once the engine has saved the changes it
    /// queued, so a quit in between can't lose them.
    @ObservationIgnored private var unsavedToken: DefaultHistoryToken?
    @ObservationIgnored private var awaitingFirstUpload = false
    /// Counts `note(_:)` calls, so Sync Now can tell whether anything failed while it ran.
    @ObservationIgnored private var problemCount = 0
    @ObservationIgnored private let sharingDelegate = SharingControllerDelegate()
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "household-sync")

    private static let memberOfKey = "household.memberOf"
    /// Set once this device has queued its first upload.
    private static let startedKey = "household.started"
    /// When a fetch or upload last finished without an error.
    private static let lastSyncedKey = "household.lastSynced"

    override init() {
        if let owner = UserDefaults.standard.string(forKey: Self.memberOfKey) {
            role = .member(ownerName: owner)
        } else {
            role = .owner
        }
        lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
        super.init()
    }

    var isMember: Bool { if case .member = role { true } else { false } }
    var isSharing: Bool { share != nil && !isMember }

    /// The household's zone: in this person's private database, or the owner's when a member.
    var zoneID: CKRecordZone.ID {
        switch role {
        case .owner: CKRecordZone.ID(zoneName: Self.zoneName)
        case .member(let ownerName): CKRecordZone.ID(zoneName: Self.zoneName, ownerName: ownerName)
        }
    }

    private var activeEngine: CKSyncEngine? { isMember ? sharedEngine : privateEngine }

    // MARK: Starting

    func start(_ modelContainer: ModelContainer) {
        guard AppConfig.cloudSyncEnabled, self.modelContainer == nil else { return }
        self.modelContainer = modelContainer
        if Persistence.startedFresh {
            // The local store was replaced: forget what was synced and download it all again.
            Store.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.startedKey)
        }
        systemFields = Store.loadFields()
        historyToken = Store.loadToken()

        privateEngine = makeEngine(database: container.privateCloudDatabase, state: Store.loadState(.private))
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: Store.loadState(.shared))
        refreshPendingCount()

        if !UserDefaults.standard.bool(forKey: Self.startedKey) {
            // First launch with household sync on this device: the owner uploads what's here.
            // Starting from the latest history means only later changes are looked at after this.
            historyToken = latestHistoryToken()
            unsavedToken = historyToken
            if isMember {
                UserDefaults.standard.set(true, forKey: Self.startedKey)
            } else {
                awaitingFirstUpload = true
                uploadEverything()
            }
        }

        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HouseholdSync.shared.scheduleLocalChanges() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                _ = Task { await HouseholdSync.shared.refreshAccount() }
            }
        })
        // Changes made while sync wasn't watching (a save just before quitting).
        sendLocalChanges()
        Task {
            await refreshAccount()
            await refreshShare()
            #if DEBUG
            await seedDevelopmentSchemaOnce()
            #endif
        }
    }

    private func makeEngine(database: CKDatabase, state: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    /// Pulls the latest now (opening the app, pull to refresh). Every screen's pull to refresh
    /// calls this: it sends what's waiting, then fetches from iCloud and returns once the
    /// changes are in the store. Does nothing when sync is off or there's no iCloud account,
    /// and never throws.
    func syncNow() async {
        guard let engine = activeEngine, !ScreenshotMode.isOn else { return }
        switch account {
        case .noAccount, .restricted, .unavailable: return
        case .checking, .available: break
        }
        // Edits saved in the last moment haven't been queued yet (that waits 400 ms).
        changeTask?.cancel()
        sendLocalChanges()
        let problemsBefore = problemCount
        do {
            try await engine.sendChanges()
        } catch {
            note(error)
        }
        do {
            try await engine.fetchChanges()
        } catch {
            note(error)
        }
        refreshPendingCount()
        // Both went through and nothing was reported meanwhile: any earlier problem is over.
        if problemCount == problemsBefore { syncProblem = nil }
    }

    func refreshAccount() async {
        guard !ScreenshotMode.isOn else { return }
        do {
            account = switch try await container.accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            default: .unavailable
            }
        } catch {
            account = .unavailable
        }
    }

    // MARK: Local changes → iCloud

    func scheduleLocalChanges() {
        changeTask?.cancel()
        changeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            sendLocalChanges()
        }
    }

    private enum LocalChange {
        case save
        case delete(recordName: String)
    }

    /// Reads the store's history since last time and queues what changed for upload.
    private func sendLocalChanges() {
        guard let context = modelContainer?.mainContext, let engine = activeEngine else { return }
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = historyToken {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(descriptor)
        } catch let error as SwiftDataError where error == .historyTokenExpired {
            // The history since the last look is gone: send everything again to be safe.
            log.notice("History token expired; queueing every record")
            historyToken = latestHistoryToken()
            unsavedToken = historyToken
            let names = SyncRegistry.allRecordNames(in: context)
            engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
            return
        } catch {
            log.error("Couldn't read history: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let last = transactions.last else { return }

        // The last thing that happened to each model, in order. A deletion that came from
        // iCloud cancels any save queued before it.
        var order: [PersistentIdentifier] = []
        var changes: [PersistentIdentifier: LocalChange] = [:]
        for transaction in transactions {
            let fromSync = transaction.author == Self.syncAuthor
            for change in transaction.changes {
                let id: PersistentIdentifier
                let local: LocalChange?
                switch change {
                case .insert(let insert):
                    if fromSync { continue }
                    id = insert.changedPersistentIdentifier
                    local = .save
                case .update(let update):
                    if fromSync { continue }
                    id = update.changedPersistentIdentifier
                    if case .delete = changes[id] { continue }
                    local = .save
                case .delete(let delete):
                    id = delete.changedPersistentIdentifier
                    if fromSync {
                        changes[id] = nil
                        order.removeAll { $0 == id }
                        continue
                    }
                    local = Self.deletedRecordName(delete).map { .delete(recordName: $0) }
                @unknown default:
                    continue
                }
                guard let local else { continue }
                if changes[id] == nil { order.append(id) }
                changes[id] = local
            }
        }

        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in order {
            switch changes[id] {
            case .save:
                guard let model = Self.liveModel(id, in: context) else { continue }
                let name = SyncRegistry.recordName(type: type(of: model).recordType, id: model.id)
                pending.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case .delete(let name):
                systemFields[name] = nil
                pending.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case nil:
                break
            }
        }
        historyToken = last.token
        if pending.isEmpty {
            Store.saveToken(historyToken)
        } else {
            // Saved with the engine's next state update, which includes these.
            unsavedToken = historyToken
            engine.state.add(pendingRecordZoneChanges: pending)
            scheduleFieldsSave()
        }
        // History before this point isn't needed again (the last one marks where we are).
        var old = HistoryDescriptor<DefaultHistoryTransaction>()
        let token = last.token
        old.predicate = #Predicate { $0.token < token }
        try? context.deleteHistory(old)
    }

    /// The model behind a history change, if it still exists (fetched, so a deleted one can't
    /// come back as a fault).
    private static func liveModel(_ id: PersistentIdentifier, in context: ModelContext) -> (any SyncedModel)? {
        func find<T: SyncedModel>(_ type: T.Type) -> (any SyncedModel)? {
            var descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        guard let type = SyncRegistry.type(named: id.entityName) else { return nil }
        return find(type)
    }

    private static func deletedRecordName(_ delete: any HistoryDelete) -> String? {
        func name<T: SyncedModel>(_ type: T.Type, _ id: UUID?) -> String? {
            id.map { SyncRegistry.recordName(type: T.recordType, id: $0) }
        }
        switch delete {
        case let change as DefaultHistoryDelete<Member>: return name(Member.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<BudgetCategory>: return name(BudgetCategory.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<LedgerEntry>: return name(LedgerEntry.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<Bill>: return name(Bill.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<Account>: return name(Account.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<LinkedBank>: return name(LinkedBank.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<PayeeRule>: return name(PayeeRule.self, change.tombstone[\.id] as? UUID)
        default: return nil
        }
    }

    private func latestHistoryToken() -> DefaultHistoryToken? {
        guard let context = modelContainer?.mainContext else { return nil }
        return (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()))?.last?.token
    }

    /// Queues every record on this device: the first time, or after iCloud lost the zone.
    private func uploadEverything() {
        guard let context = modelContainer?.mainContext, let engine = privateEngine, !isMember else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        let names = SyncRegistry.allRecordNames(in: context)
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        log.info("Queued \(names.count) records for the first upload")
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // Events from an engine that's been replaced (joining, leaving) don't count.
        guard syncEngine === privateEngine || syncEngine === sharedEngine else { return }
        let isPrivate = syncEngine === privateEngine
        switch event {
        case .stateUpdate(let update):
            Store.saveState(update.stateSerialization, isPrivate ? .private : .shared)
            if syncEngine === activeEngine {
                if let token = unsavedToken {
                    Store.saveToken(token)
                    unsavedToken = nil
                }
                if awaitingFirstUpload {
                    awaitingFirstUpload = false
                    UserDefaults.standard.set(true, forKey: Self.startedKey)
                }
            }
            refreshPendingCount()
        case .accountChange(let change):
            // Both engines report it; handle it once.
            if isPrivate { handleAccountChange(change) }
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, isPrivate: isPrivate)
        case .fetchedRecordZoneChanges(let changes):
            handleZoneChanges(changes, isPrivate: isPrivate)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine, isPrivate: isPrivate)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("Couldn't create the household zone: \(failure.error.localizedDescription, privacy: .public)")
                note(failure.error)
            }
        case .willFetchChanges, .willSendChanges:
            isSyncing = true
        case .didFetchChanges:
            isSyncing = false
            markSynced()
        case .didSendChanges:
            // Counts as synced only from `sentRecordZoneChanges` without failures.
            isSyncing = false
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await HouseholdSync.shared.record(for: recordID, engine: syncEngine)
        }
    }

    /// The record to upload for a pending save, built from the model as it is now.
    private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        guard let context = modelContainer?.mainContext,
              let model = SyncRegistry.model(named: recordID.recordName, in: context),
              let typeName = SyncRegistry.parse(recordID.recordName)?.type
        else {
            // Gone since it was queued (deleted, or a type this version doesn't know).
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let record = cachedRecord(recordID) ?? CKRecord(recordType: typeName, recordID: recordID)
        model.write(to: record)
        return record
    }

    // MARK: iCloud → local

    private func handleZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, isPrivate: Bool) {
        // Only the household this device is in. (The private database can hold other zones,
        // such as the one SwiftData's own sync used before household sync.)
        guard isPrivate != isMember, let context = modelContainer?.mainContext else { return }
        let zone = zoneID
        let modifications = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
        let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }
        guard !modifications.isEmpty || !deletions.isEmpty else { return }

        // Anything unsaved goes up as a local change first, not under the sync author.
        if context.hasChanges { try? context.save() }
        sendLocalChanges()

        // Records with an edit or deletion waiting to go up keep the local version: it's newer,
        // and wins when it's sent.
        var waiting = Set<CKRecord.ID>()
        for change in activeEngine?.state.pendingRecordZoneChanges ?? [] {
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): waiting.insert(id)
            @unknown default: break
            }
        }

        context.author = Self.syncAuthor
        defer { context.author = nil }
        for record in modifications {
            cache(record)
            guard !waiting.contains(record.recordID) else { continue }
            SyncRegistry.apply(record, in: context)
        }
        for deletion in deletions {
            systemFields[deletion.recordID.recordName] = nil
            SyncRegistry.delete(recordName: deletion.recordID.recordName, in: context)
        }
        do {
            try context.save()
        } catch {
            // Don't let these be saved later as if they were local edits.
            context.rollback()
            log.error("Couldn't save changes from iCloud: \(error.localizedDescription, privacy: .public)")
        }
        scheduleFieldsSave()
        scheduleCleanup()
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, isPrivate: Bool) {
        if isPrivate {
            // iCloud lost the household (data deleted in Settings, or keys reset): put back
            // what's on this device.
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName && !isMember {
                systemFields = [:]
                Store.saveFields(systemFields)
                share = nil
                if deletion.reason == .encryptedDataReset {
                    // The iCloud keys were reset, so the data had to go: put back what's here.
                    log.notice("Household zone reset with the encryption keys; uploading again")
                    uploadEverything()
                } else {
                    // Deleted on purpose (iCloud data removed in Settings). Keep this device's
                    // budget but don't put it back; later edits recreate the zone as they go.
                    log.notice("The household zone was deleted from iCloud")
                }
            }
            return
        }
        // Shared database: a household this account joined, maybe on another device.
        for deletion in changes.deletions where deletion.zoneID == zoneID && isMember {
            log.notice("The household was stopped or left; returning to your own budget")
            returnToOwnBudget()
        }
        if !isMember, let joined = changes.modifications.first(where: { $0.zoneID.zoneName == Self.zoneName }) {
            // Joined on another device: send anything of ours still waiting, then switch.
            let ownerName = joined.zoneID.ownerName
            Task {
                sendLocalChanges()
                try? await privateEngine?.sendChanges()
                guard !isMember else { return }
                becomeMember(ownerName: ownerName)
            }
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine, isPrivate: Bool) {
        for record in sent.savedRecords { cache(record) }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else saved it first: keep their record's version and send ours on top.
                if let server = failure.error.serverRecord { cache(server) }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                if isPrivate {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
                    systemFields[recordID.recordName] = nil
                    retry.append(.saveRecord(recordID))
                } else {
                    // The owner stopped sharing.
                    returnToOwnBudget()
                    return
                }
            case .unknownItem:
                // Our copy of its server details is stale; save it as new.
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .batchRequestFailed:
                // Failed only because another record in its batch did.
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable:
                // The engine retries these on its own.
                break
            default:
                log.error("Couldn't save \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                note(failure.error)
            }
        }
        for (recordID, error) in sent.failedRecordDeletes where error.code != .unknownItem {
            log.error("Couldn't delete \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        if sent.failedRecordSaves.isEmpty {
            lastError = nil
            syncProblem = nil
            markSynced()
        }
        refreshPendingCount()
        scheduleFieldsSave()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            Task { await refreshAccount() }
        case .signOut, .switchAccounts:
            // A different iCloud account (or none): start over with it, keeping this device's
            // budget so nothing is lost.
            log.notice("iCloud account changed; resetting household sync")
            resetSyncState()
            Task { await refreshAccount() }
        @unknown default:
            break
        }
    }

    // MARK: Sharing (owner)

    /// The household's share, creating it the first time. Saves the zone first so it exists.
    func prepareShare() async throws -> CKShare {
        if let share { return share }
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let newShare = CKShare(recordZoneID: zoneID)
        newShare[CKShare.SystemFieldKey.title] = "Suffice Household" as CKRecordValue
        newShare.publicPermission = .none
        let result = try await database.modifyRecords(saving: [newShare], deleting: [])
        guard let saved = try result.saveResults[newShare.recordID]?.get() as? CKShare else {
            throw CKError(.internalError)
        }
        share = saved
        return saved
    }

    func refreshShare() async {
        guard !ScreenshotMode.isOn else { return }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let database = isMember ? container.sharedCloudDatabase : container.privateCloudDatabase
        do {
            share = try await database.record(for: shareID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            share = nil
        } catch {
            log.error("Couldn't check the household share: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apple's sheet for inviting people and managing who's in (and stopping sharing).
    func presentSharing() async {
        isWorking = true
        defer { isWorking = false }
        do {
            // Everything waiting goes up first, so the invitee doesn't join a half-empty budget.
            try? await privateEngine?.sendChanges()
            let share = try await prepareShare()
            let controller = UICloudSharingController(share: share, container: container)
            controller.availablePermissions = [.allowReadWrite, .allowPrivate]
            controller.delegate = sharingDelegate
            controller.modalPresentationStyle = .formSheet
            UIApplication.shared.topViewController?.present(controller, animated: true)
        } catch {
            note(error)
        }
    }

    fileprivate func sharingChanged() {
        Task { await refreshShare() }
    }

    // MARK: Joining and leaving (member)

    /// From the scene delegate: someone tapped an invitation.
    func receive(_ metadata: CKShare.Metadata) {
        // The owner opening their own link, or a member opening it again, has nothing to join.
        guard metadata.participantRole != .owner else { return }
        if case .member(let ownerName) = role, ownerName == metadata.share.recordID.zoneID.ownerName { return }
        pendingInvite = metadata
    }

    /// The name of whoever sent the pending invitation.
    var inviterName: String {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return "your partner" }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? "your partner" : name
    }

    /// Joins the household in `invite`, or the pending invitation. The invitation stays
    /// pending until joining works, so a failure (offline, say) can be tried again.
    func acceptInvite(_ invite: CKShare.Metadata? = nil) async {
        guard let metadata = invite ?? pendingInvite else { return }
        isWorking = true
        joinError = nil
        defer { isWorking = false }
        do {
            // Everything of yours still waiting goes up first, so it's there if you leave.
            sendLocalChanges()
            try await privateEngine?.sendChanges()
            _ = try await container.accept(metadata)
        } catch {
            note(error)
            joinError = Self.describe(error)
            return
        }
        pendingInvite = nil
        becomeMember(ownerName: metadata.share.recordID.zoneID.ownerName)
        do {
            try await sharedEngine?.fetchChanges()
        } catch {
            note(error)
        }
    }

    /// Leaves the household: this account stops seeing it, and this device goes back to its
    /// own budget from iCloud.
    func leaveHousehold() async {
        guard isMember else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone.
        } catch {
            note(error)
            return
        }
        returnToOwnBudget()
    }

    /// Switches this device to the shared household: the local budget is replaced (it's still in
    /// this person's private iCloud), then the household downloads.
    private func becomeMember(ownerName: String) {
        log.notice("Joining the shared household")
        wipeLocalData()
        UserDefaults.standard.set(ownerName, forKey: Self.memberOfKey)
        role = .member(ownerName: ownerName)
        share = nil
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        UserDefaults.standard.removeObject(forKey: SettingsKey.askedWhoAmI)
        UserDefaults.standard.set(true, forKey: SettingsKey.onboarded)
        // Start the shared side from scratch so every record arrives. (Queued saves for the
        // wiped records drop out when they're sent; queued deletions still go.)
        systemFields = [:]
        Store.saveFields(systemFields)
        Store.saveState(nil, .shared)
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        Task {
            try? await sharedEngine?.fetchChanges()
            await refreshShare()
        }
    }

    /// Back to this person's own budget: clear the household off this device and download
    /// theirs from their private iCloud again.
    private func returnToOwnBudget() {
        guard isMember else { return }
        wipeLocalData()
        UserDefaults.standard.removeObject(forKey: Self.memberOfKey)
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        role = .owner
        if let sharedEngine { clearPending(sharedEngine) }
        systemFields = [:]
        Store.saveFields(systemFields)
        Store.saveState(nil, .private)
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        Task {
            do {
                try await privateEngine?.fetchChanges()
            } catch {
                note(error)
                return
            }
            // Nothing of theirs in iCloud: start them with the starter budgets.
            if let context = modelContainer?.mainContext, ((try? context.fetchCount(FetchDescriptor<BudgetCategory>())) ?? 0) == 0 {
                StarterData.insertBudgets(into: context)
                try? context.save()
            }
            await refreshShare()
        }
    }

    /// Who shared the household (for a member), from the share.
    var ownerName: String? {
        guard isMember, let components = share?.owner.userIdentity.nameComponents else { return nil }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? nil : name
    }

    /// Everyone invited besides the owner.
    var participants: [CKShare.Participant] {
        share?.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed } ?? []
    }

    // MARK: Helpers

    /// Deletes everything on this device without sending the deletions anywhere.
    private func wipeLocalData() {
        guard let context = modelContainer?.mainContext else { return }
        if context.hasChanges { try? context.save() }
        context.author = Self.syncAuthor
        func deleteAll<T: PersistentModel>(_ type: T.Type) {
            for model in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(model) }
        }
        deleteAll(LedgerEntry.self)
        deleteAll(Bill.self)
        deleteAll(Account.self)
        deleteAll(PayeeRule.self)
        deleteAll(LinkedBank.self)
        deleteAll(BudgetCategory.self)
        deleteAll(Member.self)
        try? context.save()
        context.author = nil
    }

    private func clearPending(_ engine: CKSyncEngine) {
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
    }

    /// After an account change: drop everything known about iCloud and download as if new.
    /// A member's copy of someone else's household is cleared first, so it can never be copied
    /// into a different account. Nothing is re-uploaded wholesale: that would overwrite edits
    /// made on other devices in the meantime; later edits go up as usual.
    private func resetSyncState() {
        if isMember { wipeLocalData() }
        Store.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.memberOfKey)
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        role = .owner
        share = nil
        systemFields = [:]
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        // A different account (or none) hasn't synced yet.
        lastSynced = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
        syncProblem = nil
        refreshPendingCount()
    }

    private func cache(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields[record.recordID.recordName] = coder.encodedData
    }

    private func cachedRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let data = systemFields[recordID.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID.zoneID == recordID.zoneID else { return nil }
        return record
    }

    private func scheduleFieldsSave() {
        fieldsSaveTask?.cancel()
        fieldsSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Store.saveFields(systemFields)
        }
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let context = modelContainer?.mainContext else { return }
            SyncCleanup.mergeDuplicates(in: context)
        }
    }

    private func note(_ error: Error) {
        lastError = Self.describe(error)
        problemCount += 1
        if let problem = Self.cardMessage(for: error) {
            syncProblem = problem
        }
        log.error("Household sync: \(error.localizedDescription, privacy: .public)")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to sync."
            case .quotaExceeded: return "Your iCloud storage is full."
            case .networkUnavailable, .networkFailure: return "No internet connection. Suffice will sync when you're back online."
            case .participantMayNeedVerification: return "Open the invitation in Messages or Mail on this device to verify it, then try again."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// The iCloud Sync card's words for an error, or nil when the card already explains it
    /// (offline, signed out of iCloud).
    private static func cardMessage(for error: Error) -> String? {
        if let error = error as? CKError {
            switch error.code {
            case .quotaExceeded:
                return "iCloud storage is full, so new changes can’t be saved there. Free up space in Settings › [your name] › iCloud."
            case .networkUnavailable, .networkFailure, .notAuthenticated, .operationCancelled:
                return nil
            default:
                break
            }
        }
        return "iCloud couldn’t sync right now. Suffice will try again on its own."
    }

    private func markSynced() {
        let now = Date.now
        lastSynced = now
        UserDefaults.standard.set(now, forKey: Self.lastSyncedKey)
    }

    private func refreshPendingCount() {
        let engines = [privateEngine, sharedEngine].compactMap { $0 }
        let count: Int? = engines.isEmpty ? nil : engines.reduce(0) { $0 + $1.state.pendingRecordZoneChanges.count }
        if count != pendingChanges { pendingChanges = count }
    }

    // MARK: Profile

    /// One line for Profile › iCloud Sync.
    var summary: String {
        guard AppConfig.cloudSyncEnabled else { return "Off" }
        switch account {
        case .checking: return "Checking…"
        case .noAccount: return "Sign in to iCloud"
        case .restricted, .unavailable: return "Unavailable"
        case .available:
            if lastError != nil { return "Needs attention" }
            if isSyncing { return "Syncing…" }
            return lastSynced == nil ? "On" : "Up to date"
        }
    }

    /// What the iCloud Sync card shows (Profile, and Profile › iCloud Sync).
    var syncSnapshot: HearthSyncSnapshot {
        guard AppConfig.cloudSyncEnabled else { return HearthSyncSnapshot(account: .unavailable(nil)) }
        let state: HearthSyncSnapshot.Account = switch account {
        case .checking: .checking
        case .available: .available
        case .noAccount: .unavailable("Sign in to iCloud in Settings to keep Suffice on all your devices and share it with your partner.")
        case .restricted: .unavailable("iCloud is restricted on this \(DeviceName.current).")
        case .unavailable: .unavailable(nil)
        }
        return HearthSyncSnapshot(
            account: state,
            isSyncing: isSyncing,
            lastSynced: lastSynced,
            pendingChanges: pendingChanges,
            errorMessage: syncProblem
        )
    }

    // MARK: Development schema

    #if DEBUG
    /// Debug builds: saves one of every record type with every field filled into the
    /// development environment, then deletes it, so the whole schema exists to deploy to
    /// production (which TestFlight and the App Store use) even before there's a bill or a rule.
    private func seedDevelopmentSchemaOnce() async {
        // Bump when a model gains a field, so the new field reaches the development schema.
        guard !UserDefaults.standard.bool(forKey: Self.schemaSeedKey), account == .available else { return }
        _ = await seedDevelopmentSchema()
    }

    private static let schemaSeedKey = "household.schemaSeeded.v2"

    /// Debug builds: saves one of every record type, every field filled, in a throwaway zone of
    /// the development environment, then deletes it. Returns what happened, for Profile ›
    /// iCloud Sync › Create Development Schema.
    func seedDevelopmentSchema() async -> String {
        await refreshAccount()
        guard account == .available else { return "iCloud isn't signed in on this device." }
        let zone = CKRecordZone(zoneName: "SchemaSeed")
        let database = container.privateCloudDatabase
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            let records = SchemaSamples.records(in: zone.zoneID)
            let result = try await database.modifyRecords(saving: records, deleting: [])
            var failures: [String] = []
            for (id, saved) in result.saveResults {
                if case .failure(let error) = saved {
                    failures.append("\(id.recordName.split(separator: ".").first ?? ""): \(error.localizedDescription)")
                }
            }
            _ = try? await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
            guard failures.isEmpty else {
                let message = "Some record types failed:\n" + failures.joined(separator: "\n")
                log.error("\(message, privacy: .public)")
                return message
            }
            UserDefaults.standard.set(true, forKey: Self.schemaSeedKey)
            log.info("Seeded the CloudKit development schema")
            return "Done: all \(records.count) record types were saved to the Development environment. In the CloudKit Console, open Deploy Schema Changes."
        } catch {
            log.error("Couldn't seed the CloudKit schema: \(error.localizedDescription, privacy: .public)")
            return "Failed: \(error.localizedDescription)"
        }
    }
    #endif
}

#if DEBUG
/// One of every record type with every field filled, for seeding the development schema.
private enum SchemaSamples {
    static func records(in zoneID: CKRecordZone.ID) -> [CKRecord] {
        let link = UUID()
        let now = Date.now
        func record<T: SyncedModel>(_ model: T) -> CKRecord {
            let name = SyncRegistry.recordName(type: T.recordType, id: model.id)
            let record = CKRecord(recordType: T.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
            model.write(to: record)
            return record
        }
        let member = Member(name: "Sample", color: .green, photoData: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let category = BudgetCategory.blank()
        category.parentID = link
        let entry = LedgerEntry.blank()
        entry.categoryID = link
        entry.memberID = link
        entry.accountID = link
        entry.billID = link
        entry.billDueDate = now
        entry.latitude = 40.4
        entry.longitude = -111.8
        entry.placeName = "Sample"
        entry.placeAddress = "Sample"
        entry.externalID = "sample"
        entry.logoURL = "https://example.com"
        entry.receiptData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let bill = Bill.blank()
        bill.minCents = 1
        bill.maxCents = 2
        bill.endDate = now
        bill.categoryID = link
        let account = Account.blank()
        account.institutionDomain = "example.com"
        account.plaidItemID = "sample"
        account.plaidAccountID = "sample"
        let bank = LinkedBank.blank()
        bank.institutionDomain = "example.com"
        bank.lastSynced = now
        let rule = PayeeRule.blank()
        rule.categoryID = link
        return [record(member), record(category), record(entry), record(bill), record(account), record(bank), record(rule)]
    }
}
#endif

// MARK: - Screenshot mode

extension HouseholdSync {
    /// Screenshot mode: iCloud signed in and just synced, without starting either sync engine.
    func startForScreenshots() {
        guard ScreenshotMode.isOn else { return }
        account = .available
        lastSynced = .now.addingTimeInterval(-90)
    }
}

// MARK: - Sharing controller

private final class SharingControllerDelegate: NSObject, UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Logger(subsystem: "com.stephenwarren.suffice", category: "household-sync")
            .error("Sharing failed: \(error.localizedDescription, privacy: .public)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        "Suffice Household"
    }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        UIImage(named: "SufficeMark")?.pngData()
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        HouseholdSync.shared.sharingChanged()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        HouseholdSync.shared.sharingChanged()
    }
}

// MARK: - Saved state

/// What household sync remembers between launches, in Application Support/Household.
private enum Store {
    enum Engine: String { case `private`, shared }

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Household", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadState(_ engine: Engine) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: folder.appending(path: "\(engine.rawValue).state")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func saveState(_ state: CKSyncEngine.State.Serialization?, _ engine: Engine) {
        let url = folder.appending(path: "\(engine.rawValue).state")
        guard let state, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func loadToken() -> DefaultHistoryToken? {
        guard let data = try? Data(contentsOf: folder.appending(path: "history.token")) else { return nil }
        return try? JSONDecoder().decode(DefaultHistoryToken.self, from: data)
    }

    static func saveToken(_ token: DefaultHistoryToken?) {
        let url = folder.appending(path: "history.token")
        guard let token, let data = try? JSONEncoder().encode(token) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func loadFields() -> [String: Data] {
        guard let data = try? Data(contentsOf: folder.appending(path: "systemFields.plist")) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    static func saveFields(_ fields: [String: Data]) {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: folder.appending(path: "systemFields.plist"), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
