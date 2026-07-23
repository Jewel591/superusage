import Foundation

public protocol UsageSnapshotReading: Sendable {
    func latestSnapshot() async throws -> CloudUsageSnapshot?
}

#if os(macOS)
/// The write surface is intentionally unavailable to iOS, iPadOS, and watchOS builds.
public protocol UsageSnapshotWriting: Sendable {
    func publish(_ snapshot: CloudUsageSnapshot) async throws
    func deleteSnapshot(sourceDeviceID: String) async throws
}
#endif

public enum UsageSnapshotStoreError: Error, LocalizedError, Sendable {
    case storeNotLoaded
    case malformedRecord
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .storeNotLoaded:
            "The usage snapshot store has not finished loading."
        case .malformedRecord:
            "The synced usage snapshot is incomplete or malformed."
        case .unsupportedSchema(let version):
            "This usage snapshot uses unsupported schema version \(version)."
        }
    }
}
