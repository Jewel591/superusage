import Foundation
import UsageSync
import XCTest
@testable import SuperUsage

final class AppleDeviceSyncStoreTests: XCTestCase {
    func testBuilderMapsPortableMetricsAndOmitsCharts() throws {
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Weekly", used: 42, limit: 100, format: .percent),
                .values(
                    label: "Today",
                    values: [MetricValue(number: 1.25, kind: .dollars, estimated: true)]
                ),
                .chart(label: "Usage Trend", points: [])
            ],
            refreshedAt: refreshedAt
        )

        let result = CloudUsageSnapshotBuilder.make(
            snapshots: [provider],
            sourceDeviceID: "mac-test",
            revision: 3,
            generatedAt: refreshedAt
        )

        XCTAssertEqual(result.revision, 3)
        XCTAssertEqual(result.providers.first?.id, "codex")
        XCTAssertEqual(result.providers.first?.metrics.count, 2)
        guard case .progress(_, _, let used, let limit, let format, _)? = result.providers.first?.metrics.first else {
            return XCTFail("Expected portable progress metric")
        }
        XCTAssertEqual(used, 42)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
    }
}
