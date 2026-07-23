import Foundation
import UsageSync
import Testing

@Suite("CloudKit Core Data snapshot store")
struct CloudKitCoreDataSnapshotStoreTests {
    @Test("requires loading before reads")
    func requiresLoad() async {
        let store = CloudKitCoreDataSnapshotStore(configuration: .inMemory())
        await #expect(throws: UsageSnapshotStoreError.self) {
            _ = try await store.latestSnapshot()
        }
    }

    #if os(macOS)
    @Test("Mac publishes and reads the newest snapshot")
    func roundTrip() async throws {
        let store = CloudKitCoreDataSnapshotStore(configuration: .inMemory())
        try await store.load()
        let snapshot = CloudUsageSnapshot(
            sourceDeviceID: "mac-test",
            revision: 7,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providers: [
                CloudProviderSnapshot(
                    id: "codex",
                    displayName: "Codex",
                    plan: "Plus",
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    metrics: [
                        .progress(
                            id: "codex.weekly",
                            label: "Weekly",
                            used: 42,
                            limit: 100,
                            format: .percent,
                            resetsAt: nil
                        )
                    ]
                )
            ]
        )

        try await store.publish(snapshot)

        #expect(try await store.latestSnapshot() == snapshot)
    }

    @Test("publishing again replaces the source device record")
    func replacesDeviceRecord() async throws {
        let store = CloudKitCoreDataSnapshotStore(configuration: .inMemory())
        try await store.load()
        let first = CloudUsageSnapshot(sourceDeviceID: "mac-test", revision: 1, providers: [])
        let second = CloudUsageSnapshot(sourceDeviceID: "mac-test", revision: 2, providers: [])

        try await store.publish(first)
        try await store.publish(second)

        #expect(try await store.latestSnapshot()?.revision == 2)
    }

    @Test("Mac can remove its published snapshot")
    func deletesDeviceRecord() async throws {
        let store = CloudKitCoreDataSnapshotStore(configuration: .inMemory())
        try await store.load()
        try await store.publish(CloudUsageSnapshot(sourceDeviceID: "mac-test", revision: 1, providers: []))

        try await store.deleteSnapshot(sourceDeviceID: "mac-test")

        #expect(try await store.latestSnapshot() == nil)
    }
    #endif
}
