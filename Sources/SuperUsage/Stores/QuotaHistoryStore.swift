import CoreData
import Foundation

/// Append-only local database of quota observations, one row per capped metric per successful refresh.
///
/// Deliberately **local-only**: it is not mirrored to CloudKit. The synced store
/// (`CloudKitCoreDataSnapshotStore`) answers "what does this Mac show right now" and holds one
/// upserted record per device; quota history is a high-cardinality append log — at the 5-minute refresh
/// cadence a single Mac writes hundreds of rows a day — so pushing it through CloudKit would multiply
/// record counts for data every Mac can collect for itself.
///
/// Retention is bounded by `retentionWindow`; see `docs/quota-history.md`.
actor QuotaHistoryStore {
    struct Configuration: Sendable {
        let name: String
        let storeURL: URL?

        init(name: String = "superUsageQuotaHistory", storeURL: URL? = nil) {
            self.name = name
            self.storeURL = storeURL
        }

        /// A throwaway SQLite store in a unique temporary directory, for tests.
        ///
        /// Deliberately a real SQLite file rather than `NSInMemoryStoreType`: the in-memory store does
        /// not support `NSBatchDeleteRequest` (the pruning path) or fetch indexes, so tests against it
        /// would exercise a different engine than production and could pass while pruning is broken.
        static func temporary(name: String = "superUsageQuotaHistoryTests") -> Self {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quota-history-\(UUID().uuidString)", isDirectory: true)
            return Self(name: name, storeURL: directory.appendingPathComponent("\(name).sqlite"))
        }
    }

    /// How far back raw samples are kept. Sized to cover the longest chart range (30 days) with slack
    /// for a Mac that was asleep across a window boundary, and matched to the 35-day expiry the local
    /// log-scan cache already uses so the app has one retention story rather than two.
    static let retentionWindow: TimeInterval = 35 * 24 * 60 * 60

    private enum Field {
        static let entity = "QuotaSampleRecord"
        static let scopeKey = "scopeKey"
        static let providerID = "providerID"
        static let accountDigest = "accountDigest"
        static let metricID = "metricID"
        static let capturedAt = "capturedAt"
        static let used = "used"
        static let limit = "limitValue"
        static let formatKind = "formatKind"
        static let formatSuffix = "formatSuffix"
        static let resetsAt = "resetsAt"
    }

    private let container: NSPersistentContainer
    private var loaded = false

    init(configuration: Configuration = Configuration()) {
        let container = NSPersistentContainer(
            name: configuration.name,
            managedObjectModel: Self.makeModel()
        )
        let storeURL = configuration.storeURL ?? Self.defaultStoreURL(name: configuration.name)
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let description = NSPersistentStoreDescription(url: storeURL)
        container.persistentStoreDescriptions = [description]
        self.container = container
    }

    func load() async throws {
        guard !loaded else { return }
        let container = self.container
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        loaded = true
    }

    /// Appends samples, skipping any whose `(scopeKey, capturedAt)` pair is already on record.
    ///
    /// The dedup exists because a snapshot can reach the recorder more than once for the same fetch —
    /// a forced refresh racing the periodic pass, or the one-shot CLI writing while the app runs — and
    /// each of those carries the *same* `refreshedAt`. Re-recording it would show as a spurious extra
    /// point rather than new information.
    func record(_ samples: [QuotaSample]) async throws {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        guard !samples.isEmpty else { return }
        let context = container.newBackgroundContext()
        // Without a merge policy a uniqueness-constraint collision throws and loses the whole batch.
        // The incoming row wins because a duplicate is by definition the same observation re-offered.
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        try await context.perform {
            // One fetch bounded to the batch's own time span, rather than a query per sample: a batch is
            // one refresh pass, so its samples land within milliseconds of each other.
            let timestamps = samples.map(\.capturedAt)
            guard let earliest = timestamps.min(), let latest = timestamps.max() else { return }
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.predicate = NSPredicate(
                format: "%K >= %@ AND %K <= %@ AND %K IN %@",
                Field.capturedAt, earliest as NSDate,
                Field.capturedAt, latest as NSDate,
                Field.scopeKey, Set(samples.map(\.scopeKey))
            )
            let existing = Set(try context.fetch(request).compactMap { record -> DedupKey? in
                guard let scopeKey = record.value(forKey: Field.scopeKey) as? String,
                      let capturedAt = record.value(forKey: Field.capturedAt) as? Date
                else { return nil }
                return DedupKey(scopeKey: scopeKey, capturedAt: capturedAt)
            })
            for sample in samples {
                let key = Self.DedupKey(scopeKey: sample.scopeKey, capturedAt: sample.capturedAt)
                guard !existing.contains(key) else { continue }
                let record = NSEntityDescription.insertNewObject(forEntityName: Field.entity, into: context)
                record.setValue(sample.scopeKey, forKey: Field.scopeKey)
                record.setValue(sample.providerID, forKey: Field.providerID)
                record.setValue(sample.accountDigest, forKey: Field.accountDigest)
                record.setValue(sample.metricID, forKey: Field.metricID)
                record.setValue(sample.capturedAt, forKey: Field.capturedAt)
                record.setValue(sample.used, forKey: Field.used)
                record.setValue(sample.limit, forKey: Field.limit)
                record.setValue(sample.format.storageKind, forKey: Field.formatKind)
                record.setValue(sample.format.countSuffix, forKey: Field.formatSuffix)
                record.setValue(sample.resetsAt, forKey: Field.resetsAt)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    /// Every sample for one series inside `[from, to]`, oldest first.
    func samples(scopeKey: String, from: Date, to: Date) async throws -> [QuotaSample] {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.predicate = NSPredicate(
                format: "%K == %@ AND %K >= %@ AND %K <= %@",
                Field.scopeKey, scopeKey,
                Field.capturedAt, from as NSDate,
                Field.capturedAt, to as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: Field.capturedAt, ascending: true)]
            return try context.fetch(request).compactMap(Self.sample(from:))
        }
    }

    /// The newest sample for one series strictly before `date`, or `nil` if the series starts inside the
    /// window.
    ///
    /// The windowed read alone cannot tell "the series genuinely begins here" from "we are looking at the
    /// middle of one": a reset or an outage straddling the left edge is only visible against the sample on
    /// the other side of it. Over-reading a fixed extra span answers that only when the neighbour happens
    /// to fall inside it — a Mac asleep for a day, or a provider that failed all night, has no sample
    /// there at all, and the chart would then open claiming the range began at whatever the first
    /// post-wake reading was. One descending fetch with `fetchLimit = 1` answers it exactly, and rides the
    /// same `(scopeKey, capturedAt)` index the windowed read uses.
    func sampleImmediatelyBefore(scopeKey: String, date: Date) async throws -> QuotaSample? {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.predicate = NSPredicate(
                format: "%K == %@ AND %K < %@",
                Field.scopeKey, scopeKey,
                Field.capturedAt, date as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: Field.capturedAt, ascending: false)]
            request.fetchLimit = 1
            return try context.fetch(request).compactMap(Self.sample(from:)).first
        }
    }

    /// The series that have at least one sample on record, newest activity first.
    func scopes() async throws -> [QuotaHistoryScope] {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.sortDescriptors = [NSSortDescriptor(key: Field.capturedAt, ascending: false)]
            // The store holds one row per metric per refresh, so folding to distinct series in memory
            // walks a lot of rows. `propertiesToFetch` + `.dictionaryResultType` keeps it to the three
            // columns that matter instead of faulting whole objects.
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [
                Field.scopeKey, Field.providerID, Field.accountDigest, Field.metricID, Field.capturedAt
            ]
            var seen: Set<String> = []
            var result: [QuotaHistoryScope] = []
            for row in try context.fetch(request) as [NSFetchRequestResult] {
                guard let dictionary = row as? [String: Any],
                      let scopeKey = dictionary[Field.scopeKey] as? String,
                      let providerID = dictionary[Field.providerID] as? String,
                      let metricID = dictionary[Field.metricID] as? String,
                      let capturedAt = dictionary[Field.capturedAt] as? Date,
                      seen.insert(scopeKey).inserted
                else { continue }
                result.append(
                    QuotaHistoryScope(
                        scopeKey: scopeKey,
                        providerID: providerID,
                        accountDigest: dictionary[Field.accountDigest] as? String,
                        metricID: metricID,
                        latestSample: capturedAt
                    )
                )
            }
            return result
        }
    }

    /// Drops every sample older than `cutoff`. Returns how many rows went, so the caller can log a
    /// prune that actually did something rather than a silent no-op.
    @discardableResult
    func prune(before cutoff: Date) async throws -> Int {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: Field.entity)
            request.predicate = NSPredicate(format: "%K < %@", Field.capturedAt, cutoff as NSDate)
            let delete = NSBatchDeleteRequest(fetchRequest: request)
            delete.resultType = .resultTypeCount
            let result = try context.execute(delete) as? NSBatchDeleteResult
            return result?.result as? Int ?? 0
        }
    }

    /// Total rows on record. Used by tests and the debug log line after a prune.
    func sampleCount() async throws -> Int {
        guard loaded else { throw QuotaHistoryStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        return try await context.perform {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Field.entity))
        }
    }

    private struct DedupKey: Hashable {
        let scopeKey: String
        let capturedAt: Date
    }

    private static func sample(from record: NSManagedObject) -> QuotaSample? {
        guard let scopeKey = record.value(forKey: Field.scopeKey) as? String,
              let providerID = record.value(forKey: Field.providerID) as? String,
              let metricID = record.value(forKey: Field.metricID) as? String,
              let capturedAt = record.value(forKey: Field.capturedAt) as? Date,
              let used = record.value(forKey: Field.used) as? Double,
              let limit = record.value(forKey: Field.limit) as? Double,
              let formatKind = record.value(forKey: Field.formatKind) as? String,
              let format = ProgressFormat(
                  storageKind: formatKind,
                  suffix: record.value(forKey: Field.formatSuffix) as? String
              )
        else { return nil }
        return QuotaSample(
            scopeKey: scopeKey,
            providerID: providerID,
            accountDigest: record.value(forKey: Field.accountDigest) as? String,
            metricID: metricID,
            capturedAt: capturedAt,
            used: used,
            limit: limit,
            format: format,
            resetsAt: record.value(forKey: Field.resetsAt) as? Date
        )
    }

    private static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = Field.entity
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute(Field.scopeKey, .stringAttributeType),
            attribute(Field.providerID, .stringAttributeType),
            attribute(Field.accountDigest, .stringAttributeType, optional: true),
            attribute(Field.metricID, .stringAttributeType),
            attribute(Field.capturedAt, .dateAttributeType),
            attribute(Field.used, .doubleAttributeType),
            attribute(Field.limit, .doubleAttributeType),
            attribute(Field.formatKind, .stringAttributeType),
            attribute(Field.formatSuffix, .stringAttributeType, optional: true),
            attribute(Field.resetsAt, .dateAttributeType, optional: true)
        ]
        // Every read is either "one series over a time range" or "walk newest-first"; both are served by
        // a composite index in that column order. Without it each chart open table-scans the whole log.
        let byScopeAndTime = NSFetchIndexDescription(
            name: "byScopeAndCapturedAt",
            elements: [
                NSFetchIndexElementDescription(
                    property: entity.propertiesByName[Field.scopeKey]!,
                    collationType: .binary
                ),
                NSFetchIndexElementDescription(
                    property: entity.propertiesByName[Field.capturedAt]!,
                    collationType: .binary
                )
            ]
        )
        // Pruning deletes purely by age across every series, so it needs its own leading-column index.
        let byTime = NSFetchIndexDescription(
            name: "byCapturedAt",
            elements: [
                NSFetchIndexElementDescription(
                    property: entity.propertiesByName[Field.capturedAt]!,
                    collationType: .binary
                )
            ]
        )
        entity.indexes = [byScopeAndTime, byTime]
        // A structural guarantee that one observation can only ever be one row. The in-context dedup in
        // `record` covers a single writer; this covers the rest — two processes writing the same fetch
        // (the app and the one-shot CLI), or a batch that races itself. Paired with a merge policy that
        // keeps the incoming row, since a re-record of the same instant carries the same values.
        entity.uniquenessConstraints = [[Field.scopeKey, Field.capturedAt]]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }

    /// Where the history lives, resolved identically from every process that writes it.
    ///
    /// Deliberately a fixed directory rather than `Bundle.main.bundleIdentifier`: that names the
    /// *running executable*, which is the app for the menu-bar process and something else for the
    /// bundled `superusage` CLI — the two would end up with separate histories. This is the same
    /// `superUsage/` directory the single-instance lock and the log-scan cache already share for
    /// exactly that reason.
    private static func defaultStoreURL(name: String) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("superUsage", isDirectory: true)
            .appendingPathComponent("\(name).sqlite", isDirectory: false)
    }
}

enum QuotaHistoryStoreError: Error, LocalizedError {
    case storeNotLoaded

    var errorDescription: String? {
        switch self {
        case .storeNotLoaded:
            return "The quota history store has not finished loading."
        }
    }
}

private extension ProgressFormat {
    /// The stable on-disk discriminator. Separate from `Codable`'s `Kind` so a change to the JSON wire
    /// shape (which the local HTTP API serves) can never silently reinterpret stored history rows.
    var storageKind: String {
        switch self {
        case .percent: return "percent"
        case .dollars: return "dollars"
        case .count: return "count"
        }
    }

    init?(storageKind: String, suffix: String?) {
        switch storageKind {
        case "percent": self = .percent
        case "dollars": self = .dollars
        case "count": self = .count(suffix: suffix ?? "")
        default: return nil
        }
    }
}
