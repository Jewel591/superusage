import CoreData
import Foundation

/// Core Data local replica mirrored to the user's private CloudKit database.
///
/// The Mac target may publish. Apple display clients only receive the reader conformance because
/// `UsageSnapshotWriting` is compiled for macOS alone.
public actor CloudKitCoreDataSnapshotStore: UsageSnapshotReading {
    public struct Configuration: Sendable {
        public let name: String
        public let cloudKitContainerIdentifier: String?
        public let storeURL: URL?
        public let inMemory: Bool

        public init(
            name: String = "superUsageSnapshots",
            cloudKitContainerIdentifier: String,
            storeURL: URL? = nil
        ) {
            self.name = name
            self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
            self.storeURL = storeURL
            self.inMemory = false
        }

        public static func inMemory(name: String = "superUsageSnapshotsTests") -> Self {
            Self(name: name, cloudKitContainerIdentifier: nil, storeURL: nil, inMemory: true)
        }

        private init(name: String, cloudKitContainerIdentifier: String?, storeURL: URL?, inMemory: Bool) {
            self.name = name
            self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
            self.storeURL = storeURL
            self.inMemory = inMemory
        }
    }

    private enum Field {
        static let entity = "UsageSnapshotRecord"
        static let id = "id"
        static let schemaVersion = "schemaVersion"
        static let sourceDeviceID = "sourceDeviceID"
        static let revision = "revision"
        static let generatedAt = "generatedAt"
        static let payload = "payload"
    }

    private let container: NSPersistentCloudKitContainer
    private var loaded = false

    public init(configuration: Configuration) {
        let container = NSPersistentCloudKitContainer(
            name: configuration.name,
            managedObjectModel: Self.makeModel()
        )
        let description = NSPersistentStoreDescription()
        if configuration.inMemory {
            description.type = NSInMemoryStoreType
        } else {
            let storeURL = configuration.storeURL ?? Self.defaultStoreURL(name: configuration.name)
            try? FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            description.url = storeURL
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if let identifier = configuration.cloudKitContainerIdentifier {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: identifier
                )
            }
        }
        container.persistentStoreDescriptions = [description]
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        self.container = container
    }

    public func load() async throws {
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

    public func latestSnapshot() async throws -> CloudUsageSnapshot? {
        guard loaded else { throw UsageSnapshotStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        let data: Data? = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.fetchLimit = 1
            request.sortDescriptors = [NSSortDescriptor(key: Field.generatedAt, ascending: false)]
            return try context.fetch(request).first?.value(forKey: Field.payload) as? Data
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CloudUsageSnapshot.self, from: data)
        guard snapshot.schemaVersion <= CloudUsageSnapshot.currentSchemaVersion else {
            throw UsageSnapshotStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    private static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = Field.entity
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute(Field.id, .UUIDAttributeType),
            attribute(Field.schemaVersion, .integer64AttributeType),
            attribute(Field.sourceDeviceID, .stringAttributeType),
            attribute(Field.revision, .integer64AttributeType),
            attribute(Field.generatedAt, .dateAttributeType),
            attribute(Field.payload, .binaryDataAttributeType)
        ]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        // CloudKit mirroring requires attributes to be optional or have defaults.
        attribute.isOptional = true
        return attribute
    }

    private static func defaultStoreURL(name: String) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let owner = Bundle.main.bundleIdentifier ?? "superUsage"
        return applicationSupport
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("\(name).sqlite", isDirectory: false)
    }
}

#if os(macOS)
extension CloudKitCoreDataSnapshotStore: UsageSnapshotWriting {
    public func publish(_ snapshot: CloudUsageSnapshot) async throws {
        guard loaded else { throw UsageSnapshotStoreError.storeNotLoaded }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.predicate = NSPredicate(format: "%K == %@", Field.sourceDeviceID, snapshot.sourceDeviceID)
            let matches = try context.fetch(request)
            let record = matches.first ?? NSEntityDescription.insertNewObject(forEntityName: Field.entity, into: context)
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
            record.setValue(snapshot.id, forKey: Field.id)
            record.setValue(Int64(snapshot.schemaVersion), forKey: Field.schemaVersion)
            record.setValue(snapshot.sourceDeviceID, forKey: Field.sourceDeviceID)
            record.setValue(snapshot.revision, forKey: Field.revision)
            record.setValue(snapshot.generatedAt, forKey: Field.generatedAt)
            record.setValue(data, forKey: Field.payload)
            if context.hasChanges {
                try context.save()
            }
        }
    }

    public func deleteSnapshot(sourceDeviceID: String) async throws {
        guard loaded else { throw UsageSnapshotStoreError.storeNotLoaded }
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: Field.entity)
            request.predicate = NSPredicate(format: "%K == %@", Field.sourceDeviceID, sourceDeviceID)
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    /// Creates or updates the development schema. Call only from an explicit development workflow.
    public func initializeDevelopmentSchema() throws {
        guard loaded else { throw UsageSnapshotStoreError.storeNotLoaded }
        try container.initializeCloudKitSchema()
    }
}
#endif
