import CloudKit
import OSLog
import SwiftData
import UIKit

/// Budget sync: the budget in iCloud, in the Hearth container's "Budget" zone.
///
/// It syncs on the Hearth household's engines (`HearthHouseholdStore`, as a
/// `HearthZoneParticipant`), so Suffice never runs a sync engine of its own, and the family
/// accepts one invitation (the household's) for everything.
///
/// Where the budget lives:
/// - Someone in their own household (a household of one is fine): their private database. When
///   the household has other parents and adults, `HearthAppSharing` shares the zone with them.
/// - Someone who joined another family's household: that family's budget, shared with them
///   automatically. The budget on this device is replaced by the shared one; theirs stays in
///   their iCloud and comes back if they leave.
///
/// - Sending: SwiftData's history says what changed locally since the last look (inserts,
///   updates, and deletions with the deleted record's ID). Those become pending changes on the
///   household's engine for the zone's database, which uploads them when it can.
/// - Receiving: the engine fetches what changed in the zone and hands it here; it's applied to
///   the store under the author `syncAuthor`, so it isn't sent back.
/// - Conflicts: the last device to save wins, field by field from that device's copy.
/// - Each family's budget keeps its own record details on this device (`Location.fileKey`), so
///   one family's data never goes up into another's zone.
@MainActor
@Observable
final class HouseholdSync: HearthZoneParticipant {
    static let shared = HouseholdSync()
    static let budgetZoneName = "Budget"
    let zoneName = HouseholdSync.budgetZoneName
    /// Marks the store changes that came from iCloud, so they aren't uploaded again.
    nonisolated static let syncAuthor = "household-sync"

    enum Location: Hashable {
        /// This account's own budget, in its private database.
        case personal
        /// Another family's budget this account was added to.
        case shared(ownerName: String)

        /// Each family's budget has its own files, so one family's data never reaches another's.
        var fileKey: String {
            switch self {
            case .personal: "personal"
            case .shared(let ownerName): "shared-" + ownerName.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            }
        }
    }

    enum AccountState: Equatable {
        case checking, available, noAccount, restricted, unavailable
    }

    private(set) var location: Location = .personal
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    /// The last problem in words for the iCloud Sync card, or nil when there's nothing to act on
    /// (offline, signed out: the card shows those itself). Cleared when a sync succeeds.
    private(set) var syncProblem: String?
    /// Changes queued that haven't gone up yet.
    private(set) var pendingChanges: Int?
    /// Switching to or from the family's budget.
    private(set) var isWorking = false
    /// This device just switched to the family's budget: the root explains what happened once.
    var showsJoinedNotice = false
    /// Downloading a whole zone (after joining, leaving or a new store).
    private(set) var isDownloading = false
    /// Screenshot mode: looks signed in without asking iCloud.
    private var screenshotAccount: AccountState?

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    /// Record names queued and not yet confirmed sent. A fetched record with a change waiting
    /// keeps the local version: it's newer, and wins when it's sent.
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var historyToken: DefaultHistoryToken?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var fieldsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var householdStarted = false
    /// The local store was replaced, or this device was in a household of Suffice's old sync:
    /// download the zone in full once the household's engines are up.
    @ObservationIgnored private var needsFullDownload = false
    @ObservationIgnored private var leftLegacyHousehold = false
    /// The first upload into the Budget zone is queued but not confirmed yet.
    @ObservationIgnored private var awaitingFirstUpload = false
    /// Counts `note(_:)` calls, so Sync Now can tell whether anything failed while it ran.
    @ObservationIgnored private var problemCount = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "household-sync")

    /// Which family's budget this account joined (its zone owner), once accepted.
    static let joinedOwnerKey = "budget.joinedOwner"
    /// Set once this device's budget has gone up into the Hearth container's Budget zone.
    private static let uploadedKey = "budget.uploadedToHearth"
    /// When a fetch or upload last finished without an error.
    private static let lastSyncedKey = "household.lastSynced"
    /// Suffice's own sync before the Hearth container (its own household zone and invite).
    private static let legacyMemberOfKey = "household.memberOf"
    private static let legacyStartedKey = "household.started"

    var household: HearthHouseholdStore { .shared }

    init() {
        lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
    }

    /// In another family's budget (it syncs through their iCloud).
    var isMember: Bool { if case .shared = location { true } else { false } }

    /// This person's budget is shared with others in their household.
    var isSharing: Bool { !isMember && !household.isMember && !participants.isEmpty }

    /// The household's people the budget is shared with (parents and adults who joined).
    var participants: [CKShare.Participant] {
        household.participants.filter { $0.acceptanceStatus == .accepted && $0.permission == .readWrite }
    }

    /// Who shared the household (for a member).
    var ownerName: String? { household.ownerName }

    var isSyncing: Bool { household.isSyncing }

    var account: AccountState {
        if let screenshotAccount { return screenshotAccount }
        switch household.account {
        case .checking: return .checking
        case .available: return .available
        case .noAccount: return .noAccount
        case .unavailable: return .unavailable
        }
    }

    /// Where the zone is now.
    var zoneLocation: (zoneID: CKRecordZone.ID, isShared: Bool)? {
        guard AppConfig.cloudSyncEnabled, !ScreenshotMode.isOn else { return nil }
        switch location {
        case .personal: return (CKRecordZone.ID(zoneName: zoneName), false)
        case .shared(let ownerName): return (CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName), true)
        }
    }

    /// The household's engines exist (they're made in `start(app:)`), so changes can be queued.
    private var isReady: Bool { started && householdStarted && household.cloudContainer != nil && zoneLocation != nil }

    /// Where the budget should be now.
    private var expectedLocation: Location {
        if case .member(let ownerName) = household.mode,
           UserDefaults.standard.string(forKey: Self.joinedOwnerKey) == ownerName {
            return .shared(ownerName: ownerName)
        }
        return .personal
    }

    /// The budget on this device is the zone's (not mid-switch, and a family's budget has been
    /// fetched at least once), so the people mirror may add people. Adding them while the
    /// family's budget is still arriving would make doubles of the ones on the way.
    var isSettled: Bool {
        guard !isWorking, !isDownloading, !leftLegacyHousehold else { return false }
        switch location {
        case .personal: return true
        case .shared: return UserDefaults.standard.bool(forKey: Self.fetchedKey(location))
        }
    }

    private static func fetchedKey(_ location: Location) -> String { "budget.fetched." + location.fileKey }

    private func markFetched() {
        guard !UserDefaults.standard.bool(forKey: Self.fetchedKey(location)) else { return }
        UserDefaults.standard.set(true, forKey: Self.fetchedKey(location))
    }

    // MARK: Starting

    /// Call at launch, before the household store starts (it registers the Budget zone).
    func start(_ modelContainer: ModelContainer) {
        guard AppConfig.cloudSyncEnabled, !ScreenshotMode.isOn, !started else { return }
        started = true
        self.modelContainer = modelContainer
        household.register(self)
        // Suffice's own sync (its own container and invite) is gone; forget what it kept.
        LegacyStore.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.legacyStartedKey)
        if UserDefaults.standard.string(forKey: Self.legacyMemberOfKey) != nil {
            // This device showed someone else's budget from the old sync. It must never go up
            // into this person's own zone: it comes back through the household instead. The
            // key stays until the copy is wiped (`householdDidStart`), and nothing is sent
            // while it's set, so quitting in between can't upload it.
            leftLegacyHousehold = true
        }
        if Persistence.startedFresh {
            // The local store was replaced: forget what was synced and download it all again.
            Store.removeAll()
            needsFullDownload = true
        }
        location = expectedLocation
        load()
        historyToken = Store.loadToken()
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HouseholdSync.shared.scheduleLocalChanges() }
        })
    }

    /// Call right after `HearthHouseholdStore.shared.start(app:)`: the engines are up, so the
    /// first upload and anything saved meanwhile can be queued.
    func householdDidStart() {
        guard started, !householdStarted, household.cloudContainer != nil else { return }
        householdStarted = true
        refreshLocation()
        if leftLegacyHousehold {
            log.notice("Leaving the old Suffice household; the family's budget comes through the Hearth household")
            guard wipeLocalData() else {
                // Tried again next launch; nothing is sent meanwhile.
                log.error("Couldn't clear the old shared budget; trying again next launch")
                return
            }
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
            historyToken = latestHistoryToken()
            Store.saveToken(historyToken)
            UserDefaults.standard.set(true, forKey: Self.uploadedKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyMemberOfKey)
            leftLegacyHousehold = false
            needsFullDownload = true
        }
        if !UserDefaults.standard.bool(forKey: Self.uploadedKey) {
            // First launch with the Hearth container: this device's budget goes up into the new
            // zone. Starting from the latest history means only later changes are looked at.
            historyToken = latestHistoryToken()
            Store.saveToken(historyToken)
            if location == .personal {
                uploadEverything()
            } else {
                UserDefaults.standard.set(true, forKey: Self.uploadedKey)
            }
        }
        // Joined a family's budget but quit before it had all arrived: fetch it again.
        if isMember, !UserDefaults.standard.bool(forKey: Self.fetchedKey(location)) {
            needsFullDownload = true
        }
        // Changes made while sync wasn't watching (a save just before quitting).
        sendLocalChanges()
        if needsFullDownload {
            needsFullDownload = false
            Task { await downloadWholeZone(addStarterBudgets: true) }
        }
        Task {
            await updateSharing()
            #if DEBUG
            await seedDevelopmentSchemaOnce()
            #endif
        }
    }

    /// Shares the budget with the household (owner) or joins the family's (everyone else). Call
    /// on launch, coming to the foreground and when the household changes.
    func updateSharing() async {
        guard isReady, household.exists else { return }
        var joinedOwner: String?
        await HearthAppSharing.update(app: .suffice, zoneName: zoneName, title: "Budget", audience: .adults) { owner in
            joinedOwner = owner
        }
        if let joinedOwner, location != .shared(ownerName: joinedOwner) {
            await joinFamilyBudget(joinedOwner)
        }
    }

    /// Pulls the latest now (opening the app, pull to refresh). Every screen's pull to refresh
    /// calls this: it sends what's waiting, then fetches from iCloud and returns once the
    /// changes are in the store. Does nothing when sync is off or there's no iCloud account,
    /// and never throws.
    func syncNow() async {
        guard isReady, let zone = zoneLocation else { return }
        switch account {
        case .noAccount, .restricted, .unavailable: return
        case .checking, .available: break
        }
        // Edits saved in the last moment haven't been queued yet (that waits 400 ms).
        changeTask?.cancel()
        sendLocalChanges()
        let problemsBefore = problemCount
        let sentBefore = pending
        await household.syncZoneNow(isShared: zone.isShared)
        if household.account == .available, household.problem == nil {
            // Everything queued before went up.
            pending.subtract(sentBefore)
            refreshPendingCount()
            scheduleFieldsSave()
            markSynced()
        }
        // Nothing was reported meanwhile: any earlier problem is over.
        if problemCount == problemsBefore { syncProblem = nil }
    }

    func refreshAccount() async {
        guard !ScreenshotMode.isOn else { return }
        await household.refreshAccount()
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

    /// Reads the store's history since last time and queues what changed for upload, into the
    /// zone the budget is in now.
    private func sendLocalChanges() {
        guard isReady, !leftLegacyHousehold, let context = modelContainer?.mainContext, let zone = zoneLocation else { return }
        let zoneID = zone.zoneID
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
            Store.saveToken(historyToken)
            let names = SyncRegistry.allRecordNames(in: context)
            queue(names.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
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

        var queued: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in order {
            switch changes[id] {
            case .save:
                guard let model = Self.liveModel(id, in: context) else { continue }
                let name = SyncRegistry.recordName(type: type(of: model).recordType, id: model.id)
                queued.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case .delete(let name):
                systemFields[name] = nil
                queued.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case nil:
                break
            }
        }
        historyToken = last.token
        queue(queued)
        // Saved with the record details a moment later, after the engine has the changes.
        scheduleFieldsSave()
        // History before this point isn't needed again (the last one marks where we are).
        var old = HistoryDescriptor<DefaultHistoryTransaction>()
        let token = last.token
        old.predicate = #Predicate { $0.token < token }
        try? context.deleteHistory(old)
    }

    /// Hands changes to the household's engine for the zone's database.
    private func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard !changes.isEmpty, !leftLegacyHousehold, let zone = zoneLocation else { return }
        if !zone.isShared { household.ensurePrivateZone(zone.zoneID) }
        household.queueZoneChanges(changes, isShared: zone.isShared)
        for change in changes {
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): pending.insert(id.recordName)
            @unknown default: break
            }
        }
        refreshPendingCount()
        scheduleFieldsSave()
    }

    /// The model behind a history change, if it still exists (fetched, so a deleted one can't
    /// come back as a fault).
    private static func liveModel(_ id: PersistentIdentifier, in context: ModelContext) -> (any SyncedModel)? {
        func find<T: SyncedModel>(_ type: T.Type) -> (any SyncedModel)? {
            var descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        guard let type = SyncRegistry.type(entityName: id.entityName) else { return nil }
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
        case let change as DefaultHistoryDelete<Loan>: return name(Loan.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<OwnedAsset>: return name(OwnedAsset.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<NetWorthSnapshot>: return name(NetWorthSnapshot.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<Stash>: return name(Stash.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<StashMove>: return name(StashMove.self, change.tombstone[\.id] as? UUID)
        case let change as DefaultHistoryDelete<BillStatement>: return name(BillStatement.self, change.tombstone[\.id] as? UUID)
        default: return nil
        }
    }

    private func latestHistoryToken() -> DefaultHistoryToken? {
        guard let context = modelContainer?.mainContext else { return nil }
        return (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()))?.last?.token
    }

    /// Queues every record on this device into this person's own zone: the first time, or
    /// after iCloud lost the zone with the encryption keys.
    private func uploadEverything() {
        guard location == .personal, let context = modelContainer?.mainContext else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        household.ensurePrivateZone(zoneID)
        let names = SyncRegistry.allRecordNames(in: context)
        if names.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.uploadedKey)
            return
        }
        awaitingFirstUpload = !UserDefaults.standard.bool(forKey: Self.uploadedKey)
        queue(names.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        log.info("Queued \(names.count) records for upload")
    }

    // MARK: HearthZoneParticipant

    /// The record to upload for a pending save, built from the model as it is now. Only for the
    /// zone the budget is in now: anything queued for another zone drops out.
    func zoneRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == zoneLocation?.zoneID,
              let context = modelContainer?.mainContext,
              let model = SyncRegistry.model(named: recordID.recordName, in: context),
              let typeName = SyncRegistry.parse(recordID.recordName)?.type
        else {
            // Gone since it was queued (deleted, or a type this version doesn't know).
            pending.remove(recordID.recordName)
            refreshPendingCount()
            return nil
        }
        let record = cachedRecord(recordID) ?? CKRecord(recordType: typeName, recordID: recordID)
        model.write(to: record)
        return record
    }

    func zoneFetched(modifications: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion]) {
        apply(modifications: modifications, deletedNames: deletions.map(\.recordID.recordName))
        markSynced()
    }

    /// Takes in records from iCloud. Records with an edit or deletion waiting to go up keep the
    /// local version.
    private func apply(modifications: [CKRecord], deletedNames: [String]) {
        guard let context = modelContainer?.mainContext, !modifications.isEmpty || !deletedNames.isEmpty else { return }
        // Anything unsaved goes up as a local change first, not under the sync author.
        if context.hasChanges { try? context.save() }
        sendLocalChanges()

        context.author = Self.syncAuthor
        defer { context.author = nil }
        for record in modifications {
            cache(record)
            guard !pending.contains(record.recordID.recordName) else { continue }
            SyncRegistry.apply(record, in: context)
        }
        for name in deletedNames {
            systemFields[name] = nil
            SyncRegistry.delete(recordName: name, in: context)
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

    func zoneSent(saved: [CKRecord], deleted: [CKRecord.ID], failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], isShared: Bool) -> [CKSyncEngine.PendingRecordZoneChange] {
        // Sent for a zone the budget has since left: nothing to keep.
        guard isShared == zoneLocation?.isShared else { return [] }
        for record in saved {
            cache(record)
            pending.remove(record.recordID.recordName)
        }
        for recordID in deleted { pending.remove(recordID.recordName) }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in failedSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else saved it first: keep their record's version and send ours on top.
                if let server = failure.error.serverRecord { cache(server) }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                if isShared {
                    // The family stopped sharing the budget, or removed this person.
                    leaveFamilyBudget()
                    return []
                }
                household.ensurePrivateZone(recordID.zoneID)
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
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
                pending.remove(recordID.recordName)
                note(failure.error)
            }
        }
        if failedSaves.isEmpty {
            lastError = nil
            syncProblem = nil
            markSynced()
            if awaitingFirstUpload, !saved.isEmpty {
                awaitingFirstUpload = false
                UserDefaults.standard.set(true, forKey: Self.uploadedKey)
            }
        }
        refreshPendingCount()
        scheduleFieldsSave()
        return retry
    }

    func zoneDatabaseChanged(added: [CKRecordZone.ID], deleted: [CKDatabase.DatabaseChange.Deletion], isShared: Bool) {
        guard isShared else {
            guard location == .personal else { return }
            for deletion in deleted where deletion.zoneID.zoneName == zoneName {
                systemFields = [:]
                Store.saveFields(systemFields, location.fileKey)
                if deletion.reason == .encryptedDataReset {
                    // The iCloud keys were reset, so the data had to go: put back what's here.
                    log.notice("Budget zone reset with the encryption keys; uploading again")
                    uploadEverything()
                } else {
                    // Deleted on purpose (iCloud data removed in Settings). Keep this device's
                    // budget but don't put it back; later edits recreate the zone as they go.
                    log.notice("The budget zone was deleted from iCloud")
                }
            }
            return
        }
        if case .member(let ownerName) = household.mode, added.contains(where: { $0.ownerName == ownerName }) {
            // Accepted on another device, or by `updateSharing`.
            Task { await joinFamilyBudget(ownerName) }
        }
        if case .shared(let ownerName) = location, deleted.contains(where: { $0.zoneID.ownerName == ownerName }) {
            log.notice("The family's budget was stopped or left; returning to your own budget")
            leaveFamilyBudget()
        }
    }

    /// An engine started over (joining or leaving a household, another Hearth app moving): it
    /// downloads its zones again, and what was queued on the old one is gone. The changes this
    /// device was still waiting to send are queued again on the new one (a save for a model
    /// that's still here, a deletion otherwise). Nothing else is re-uploaded wholesale: that
    /// would overwrite newer edits from other devices.
    func zoneEngineReset(isShared: Bool) {
        refreshLocation()
        guard let zone = zoneLocation, zone.isShared == isShared else { return }
        guard let context = modelContainer?.mainContext, !pending.isEmpty else { return }
        let waiting = pending
        pending = []
        let changes = waiting.sorted().map { name -> CKSyncEngine.PendingRecordZoneChange in
            let recordID = CKRecord.ID(recordName: name, zoneID: zone.zoneID)
            return SyncRegistry.model(named: name, in: context) != nil ? .saveRecord(recordID) : .deleteRecord(recordID)
        }
        queue(changes)
        refreshPendingCount()
        scheduleFieldsSave()
    }

    /// A different iCloud account (or none): start over with it, keeping this device's own
    /// budget so nothing is lost. A copy of someone else's budget is cleared first, so it can
    /// never be copied into a different account.
    func zoneAccountDidChange() {
        log.notice("iCloud account changed; resetting budget sync")
        if isMember {
            wipeLocalData()
            UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        }
        UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
        Store.removeAll()
        location = .personal
        systemFields = [:]
        pending = []
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        // Not uploaded wholesale into the new account; later edits go up as usual.
        UserDefaults.standard.set(true, forKey: Self.uploadedKey)
        awaitingFirstUpload = false
        lastSynced = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
        syncProblem = nil
        refreshPendingCount()
    }

    // MARK: Joining and leaving the family's budget

    /// Follows the household: left that family's household, or joined and accepted the budget.
    func refreshLocation() {
        guard started else { return }
        if case .shared(let ownerName) = location, household.mode != .member(ownerName: ownerName) {
            leaveFamilyBudget()
        }
        if case .shared(let ownerName) = expectedLocation, location != .shared(ownerName: ownerName) {
            Task { await joinFamilyBudget(ownerName) }
        }
    }

    /// Switches this device to the family's budget: what's waiting of this person's own goes
    /// up first, then the budget here is replaced by the shared one (theirs stays in their own
    /// iCloud and comes back if they leave).
    private func joinFamilyBudget(_ ownerName: String) async {
        guard started, !isWorking, household.mode == .member(ownerName: ownerName),
              location != .shared(ownerName: ownerName) else { return }
        isWorking = true
        defer { isWorking = false }
        if location == .personal, isReady {
            sendLocalChanges()
            await household.syncZoneNow(isShared: false)
        }
        // The household may have changed while that ran.
        guard household.mode == .member(ownerName: ownerName), location != .shared(ownerName: ownerName) else { return }
        log.notice("Joining the family's budget")
        UserDefaults.standard.set(ownerName, forKey: Self.joinedOwnerKey)
        Store.saveFields(systemFields, location.fileKey)
        changeTask?.cancel()
        wipeLocalData()
        location = .shared(ownerName: ownerName)
        load()
        pending = []
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        refreshPendingCount()
        // Whoever uses this device picks themselves in the household; the mirror sets it here.
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        UserDefaults.standard.set(true, forKey: SettingsKey.onboarded)
        showsJoinedNotice = true
        await downloadWholeZone(addStarterBudgets: false)
        await household.syncZoneNow(isShared: true)
    }

    /// Back to this person's own budget: the family's is cleared off this device and theirs
    /// downloads from their private iCloud again.
    private func leaveFamilyBudget() {
        guard case .shared = location else { return }
        log.notice("Leaving the family's budget")
        UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
        UserDefaults.standard.removeObject(forKey: SettingsKey.currentMember)
        changeTask?.cancel()
        fieldsSaveTask?.cancel()
        Store.remove(location.fileKey)
        UserDefaults.standard.removeObject(forKey: Self.fetchedKey(location))
        wipeLocalData()
        location = .personal
        load()
        pending = []
        historyToken = latestHistoryToken()
        Store.saveToken(historyToken)
        refreshPendingCount()
        Task { await downloadWholeZone(addStarterBudgets: true) }
    }

    /// Fetches everything in the zone the budget is in now (after joining, leaving or a new
    /// store), straight from the database: the household's engine has already been past it.
    private func downloadWholeZone(addStarterBudgets: Bool) async {
        guard let zone = zoneLocation, let container = household.cloudContainer else { return }
        let database = zone.isShared ? container.sharedCloudDatabase : container.privateCloudDatabase
        let fetching = location
        isDownloading = true
        defer { isDownloading = false }
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let result = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
                for modification in result.modificationResultsByID.values {
                    if case .success(let change) = modification { records.append(change.record) }
                }
                token = result.changeToken
                if !result.moreComing { break }
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Nothing there yet.
        } catch {
            note(error)
            return
        }
        // Moved somewhere else meanwhile: these belong to the other budget.
        guard location == fetching else { return }
        apply(modifications: records, deletedNames: [])
        markFetched()
        markSynced()
        // Nothing of theirs in iCloud: start them with the starter budgets.
        if addStarterBudgets, location == .personal, let context = modelContainer?.mainContext,
           ((try? context.fetchCount(FetchDescriptor<BudgetCategory>())) ?? 0) == 0 {
            StarterData.insertBudgets(into: context)
            try? context.save()
        }
    }

    // MARK: Helpers

    private func load() {
        systemFields = Store.loadFields(location.fileKey)
        pending = Store.loadPending(location.fileKey)
        refreshPendingCount()
    }

    /// Deletes everything on this device without sending the deletions anywhere. Returns
    /// whether it worked.
    @discardableResult
    private func wipeLocalData() -> Bool {
        guard let context = modelContainer?.mainContext else { return false }
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
        deleteAll(Loan.self)
        deleteAll(OwnedAsset.self)
        deleteAll(NetWorthSnapshot.self)
        deleteAll(StashMove.self)
        deleteAll(Stash.self)
        deleteAll(BillStatement.self)
        deleteAll(FoundReceipt.self)
        deleteAll(BudgetCategory.self)
        deleteAll(Member.self)
        defer { context.author = nil }
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            log.error("Couldn't clear the budget on this device: \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    /// Record details, waiting changes and the history position, a moment after they change
    /// (by then the engine has saved what was queued).
    private func scheduleFieldsSave() {
        fieldsSaveTask?.cancel()
        let key = location.fileKey
        fieldsSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, location.fileKey == key else { return }
            Store.saveFields(systemFields, key)
            Store.savePending(pending, key)
            Store.saveToken(historyToken)
        }
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let context = modelContainer?.mainContext else { return }
            SyncCleanup.mergeDuplicates(in: context)
            // Stashes another device made (or counted) may owe a 1st here.
            StashScheduler.run(in: context)
        }
    }

    private func note(_ error: Error) {
        lastError = Self.describe(error)
        problemCount += 1
        if let problem = Self.cardMessage(for: error) {
            syncProblem = problem
        }
        log.error("Budget sync: \(error.localizedDescription, privacy: .public)")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to sync."
            case .quotaExceeded: return "Your iCloud storage is full."
            case .networkUnavailable, .networkFailure: return "No internet connection. Suffice will sync when you're back online."
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
        let count: Int? = isReady ? pending.count : nil
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
        case .noAccount: .unavailable("Sign in to iCloud in Settings to keep Suffice on all your devices and share it with your household.")
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

    /// v3: the Hearth container (the budget moved there, and its people are "BudgetMember").
    private static let schemaSeedKey = "household.schemaSeeded.v3"

    /// Debug builds: saves one of every record type, every field filled, in a throwaway zone of
    /// the Hearth container's development environment, then deletes it. Returns what happened,
    /// for Profile › CloudKit (Debug) › Create Development Schema.
    func seedDevelopmentSchema() async -> String {
        await refreshAccount()
        guard account == .available else { return "iCloud isn't signed in on this device." }
        let container = household.cloudContainer ?? CKContainer(identifier: HearthHouseholdStore.containerID)
        let zone = CKRecordZone(zoneName: "SufficeSchemaSeed")
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
            return "Done: all \(records.count) record types were saved to the Development environment of \(HearthHouseholdStore.containerID). In the CloudKit Console, open Deploy Schema Changes."
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
        category.isEssential = true
        category.taxTag = .charitable
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
        entry.splits = [EntrySplit(categoryID: link, amountCents: 1, taxTag: .business), EntrySplit(categoryID: link, amountCents: 1)]
        entry.stashID = link
        entry.stashCents = 1
        entry.taxTag = .medical
        entry.receiptSourceRaw = "email"
        entry.receiptLink = "https://example.com"
        entry.logoURL = "https://example.com"
        entry.receiptData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let bill = Bill.blank()
        bill.minCents = 1
        bill.maxCents = 2
        bill.endDate = now
        bill.categoryID = link
        bill.payURL = "https://example.com"
        let account = Account.blank()
        account.institutionDomain = "example.com"
        account.plaidItemID = "sample"
        account.plaidAccountID = "sample"
        account.isEmergencyFund = true
        let bank = LinkedBank.blank()
        bank.institutionDomain = "example.com"
        bank.lastSynced = now
        let rule = PayeeRule.blank()
        rule.categoryID = link
        rule.taxTag = .hsa
        let loan = Loan.blank()
        loan.accountID = link
        let asset = OwnedAsset.blank()
        let snapshot = NetWorthSnapshot.blank()
        let stash = Stash.blank()
        stash.accountID = link
        stash.billID = link
        let move = StashMove.blank()
        let statement = BillStatement.blank()
        statement.billID = link
        statement.periodStart = now
        statement.periodEnd = now
        statement.charges = [StatementCharge(name: "Sample", amountCents: 1)]
        statement.sender = "Sample"
        statement.fileName = "sample.pdf"
        statement.emailID = "sample"
        statement.documentData = Data([0x25, 0x50, 0x44, 0x46])
        return [record(member), record(category), record(entry), record(bill), record(account), record(bank), record(rule), record(loan), record(asset), record(snapshot), record(stash), record(move), record(statement)]
    }
}
#endif

// MARK: - Screenshot mode

extension HouseholdSync {
    /// Screenshot mode: iCloud signed in and just synced, without starting anything.
    func startForScreenshots() {
        guard ScreenshotMode.isOn else { return }
        screenshotAccount = .available
        lastSynced = .now.addingTimeInterval(-90)
    }
}

// MARK: - Saved state

/// What budget sync remembers between launches, in Application Support/Budget: the history
/// position, and for each budget (`Location.fileKey`) its records' CloudKit details and the
/// changes still waiting to go up.
private enum Store {
    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Budget", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fieldsURL(_ key: String) -> URL { folder.appending(path: "\(key)-fields.plist", directoryHint: .notDirectory) }
    private static func pendingURL(_ key: String) -> URL { folder.appending(path: "\(key)-pending.plist", directoryHint: .notDirectory) }

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

    static func loadFields(_ key: String) -> [String: Data] {
        guard let data = try? Data(contentsOf: fieldsURL(key)) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    static func saveFields(_ fields: [String: Data], _ key: String) {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: fieldsURL(key), options: .atomic)
    }

    static func loadPending(_ key: String) -> Set<String> {
        guard let data = try? Data(contentsOf: pendingURL(key)) else { return [] }
        return Set((try? PropertyListDecoder().decode([String].self, from: data)) ?? [])
    }

    static func savePending(_ pending: Set<String>, _ key: String) {
        guard let data = try? PropertyListEncoder().encode(pending.sorted()) else { return }
        try? data.write(to: pendingURL(key), options: .atomic)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fieldsURL(key))
        try? FileManager.default.removeItem(at: pendingURL(key))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Suffice's own sync before the Hearth container kept its engines' state in
/// Application Support/Household.
private enum LegacyStore {
    static func removeAll() {
        let url = URL.applicationSupportDirectory.appending(path: "Household", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
    }
}
