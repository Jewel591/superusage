import Foundation
import Testing
@testable import SuperUsage

struct SuperUsageISO8601Tests {
    @Test func parsesZuluISO() {
        let date = SuperUsageISO8601.date(from: "2099-01-01T00:00:00.000Z")
        #expect(date != nil)
    }

    @Test func normalizesMicrosecondsWithoutTimezoneLikeClaudeAPI() {
        let date = SuperUsageISO8601.date(from: "2099-01-01T00:00:00.123456")
        #expect(date != nil)
        #expect(SuperUsageISO8601.string(from: date!) == "2099-01-01T00:00:00.123Z")
    }

    @Test func normalizesSpaceSeparatedUTC() {
        let date = SuperUsageISO8601.date(from: "2099-01-01 00:00:00 UTC")
        #expect(date != nil)
    }
}
