import Foundation

/// Transport-neutral snapshot written by the Mac authority and read by display-only clients.
public struct CloudUsageSnapshot: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let sourceDeviceID: String
    public let revision: Int64
    public let generatedAt: Date
    public let providers: [CloudProviderSnapshot]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceDeviceID: String,
        revision: Int64,
        generatedAt: Date = Date(),
        providers: [CloudProviderSnapshot]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sourceDeviceID = sourceDeviceID
        self.revision = revision
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct CloudProviderSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let plan: String?
    public let refreshedAt: Date
    public let metrics: [CloudUsageMetric]

    public init(
        id: String,
        displayName: String,
        plan: String? = nil,
        refreshedAt: Date,
        metrics: [CloudUsageMetric]
    ) {
        self.id = id
        self.displayName = displayName
        self.plan = plan
        self.refreshedAt = refreshedAt
        self.metrics = metrics
    }
}

public enum CloudMetricFormat: String, Codable, Hashable, Sendable {
    case percent
    case dollars
    case count
}

public struct CloudMetricValue: Codable, Hashable, Sendable {
    public let number: Double
    public let format: CloudMetricFormat
    public let unit: String?
    public let estimated: Bool

    public init(number: Double, format: CloudMetricFormat, unit: String? = nil, estimated: Bool = false) {
        self.number = number
        self.format = format
        self.unit = unit
        self.estimated = estimated
    }
}

public enum CloudUsageMetric: Codable, Hashable, Sendable, Identifiable {
    case progress(
        id: String,
        label: String,
        used: Double,
        limit: Double,
        format: CloudMetricFormat,
        resetsAt: Date?
    )
    case values(id: String, label: String, values: [CloudMetricValue])
    case text(id: String, label: String, value: String)
    case badge(id: String, label: String, value: String)

    public var id: String {
        switch self {
        case .progress(let id, _, _, _, _, _),
             .values(let id, _, _),
             .text(let id, _, _),
             .badge(let id, _, _):
            id
        }
    }

    public var label: String {
        switch self {
        case .progress(_, let label, _, _, _, _),
             .values(_, let label, _),
             .text(_, let label, _),
             .badge(_, let label, _):
            label
        }
    }
}
