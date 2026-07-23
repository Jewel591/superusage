import Foundation
import Observation
import UsageSync

enum AppleDeviceSyncConfiguration {
    static let defaultContainerIdentifier = "iCloud.com.weisenjoytech.usage.sync"

    static var containerIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "SuperUsageCloudKitContainerIdentifier") as? String
            ?? defaultContainerIdentifier
    }
}

@MainActor
@Observable
final class AppleDeviceSyncStore {
    static let enabledKey = "superusage.appleDeviceSync.enabled.v1"
    private static let revisionKey = "superusage.appleDeviceSync.revision.v1"

    private let defaults: UserDefaults
    private let dataStore: WidgetDataStore
    private let deviceID: String
    private let containerIdentifier: String
    private let writeDebounce: Duration
    private var store: CloudKitCoreDataSnapshotStore?
    private var writeTask: Task<Void, Never>?

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            Task { await applyEnabledChange() }
        }
    }
    private(set) var isSyncing = false
    private(set) var lastPublishedAt: Date?
    private(set) var serviceError: String?

    init(
        dataStore: WidgetDataStore,
        deviceID: String,
        defaults: UserDefaults = .standard,
        containerIdentifier: String = AppleDeviceSyncConfiguration.containerIdentifier,
        writeDebounce: Duration = .seconds(3)
    ) {
        self.dataStore = dataStore
        self.deviceID = deviceID
        self.defaults = defaults
        self.containerIdentifier = containerIdentifier
        self.writeDebounce = writeDebounce
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        dataStore.onAppleDeviceSnapshotChanged = { [weak self] in self?.schedulePublish() }
        if enabled {
            Task { await publishNow() }
        }
    }

    func schedulePublish() {
        guard enabled else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            await publishNow()
        }
    }

    func publishNow() async {
        guard enabled else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let store = try await resolvedStore()
            let revision = nextRevision()
            let snapshot = CloudUsageSnapshotBuilder.make(
                snapshots: dataStore.appleDeviceExportSnapshots(),
                sourceDeviceID: deviceID,
                revision: revision
            )
            try await store.publish(snapshot)
            lastPublishedAt = snapshot.generatedAt
            serviceError = nil
            AppLog.info(.config, "Apple device snapshot published (revision \(revision))")
        } catch {
            serviceError = error.localizedDescription
            let nsError = error as NSError
            AppLog.warn(
                .config,
                "Apple device snapshot publish failed: \(error.localizedDescription) "
                    + "(domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo))"
            )
        }
    }

    private func applyEnabledChange() async {
        writeTask?.cancel()
        if enabled {
            await publishNow()
        } else {
            do {
                let store = try await resolvedStore()
                try await store.deleteSnapshot(sourceDeviceID: deviceID)
                lastPublishedAt = nil
                serviceError = nil
            } catch {
                serviceError = error.localizedDescription
                let nsError = error as NSError
                AppLog.warn(
                    .config,
                    "Apple device snapshot delete failed: \(error.localizedDescription) "
                        + "(domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo))"
                )
            }
        }
    }

    private func resolvedStore() async throws -> CloudKitCoreDataSnapshotStore {
        if let store { return store }
        let store = CloudKitCoreDataSnapshotStore(
            configuration: .init(cloudKitContainerIdentifier: containerIdentifier)
        )
        try await store.load()
        if ProcessInfo.processInfo.environment["SUPERUSAGE_INITIALIZE_CLOUDKIT_SCHEMA"] == "1" {
            try await store.initializeDevelopmentSchema()
        }
        self.store = store
        return store
    }

    private func nextRevision() -> Int64 {
        let revision = max(0, (defaults.object(forKey: Self.revisionKey) as? NSNumber)?.int64Value ?? 0) + 1
        defaults.set(revision, forKey: Self.revisionKey)
        return revision
    }
}

enum CloudUsageSnapshotBuilder {
    static func make(
        snapshots: [ProviderSnapshot],
        sourceDeviceID: String,
        revision: Int64,
        generatedAt: Date = Date()
    ) -> CloudUsageSnapshot {
        CloudUsageSnapshot(
            sourceDeviceID: sourceDeviceID,
            revision: revision,
            generatedAt: generatedAt,
            providers: snapshots.map(provider)
        )
    }

    private static func provider(_ snapshot: ProviderSnapshot) -> CloudProviderSnapshot {
        CloudProviderSnapshot(
            id: snapshot.providerID,
            displayName: snapshot.displayName,
            plan: snapshot.plan,
            refreshedAt: snapshot.refreshedAt,
            metrics: snapshot.lines.enumerated().compactMap { index, line in
                metric(line, providerID: snapshot.providerID, index: index)
            }
        )
    }

    private static func metric(_ line: MetricLine, providerID: String, index: Int) -> CloudUsageMetric? {
        let id = "\(providerID).\(index).\(slug(line.label))"
        switch line {
        case .progress(let label, let used, let limit, let format, let resetsAt, _, _):
            return .progress(
                id: id,
                label: label,
                used: used,
                limit: limit,
                format: format.metricKind.cloudFormat,
                resetsAt: resetsAt
            )
        case .values(let label, let values, _, _, _, _):
            return .values(
                id: id,
                label: label,
                values: values.map {
                    CloudMetricValue(
                        number: $0.number,
                        format: $0.kind.cloudFormat,
                        unit: $0.label,
                        estimated: $0.estimated
                    )
                }
            )
        case .text(let label, let value, _, _):
            return .text(id: id, label: label, value: value)
        case .badge(let label, let text, _, _):
            return .badge(id: id, label: label, value: text)
        case .chart:
            return nil
        }
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
    }
}

private extension MetricKind {
    var cloudFormat: CloudMetricFormat {
        switch self {
        case .percent: .percent
        case .dollars: .dollars
        case .count: .count
        }
    }
}
