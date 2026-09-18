import XCTest
@testable import CPAQuotaCore

final class CPAQuotaCoreTests: XCTestCase {
    func testTotalSuccessRate() {
        let buckets = [
            RequestBucket(time: "10:00-10:10", success: 8, failed: 2),
            RequestBucket(time: "10:10-10:20", success: 2, failed: 0),
        ]
        XCTAssertEqual(QuotaMath.totalSuccessRate(buckets), 1000.0 / 12.0, accuracy: 0.001)
        XCTAssertNil(QuotaMath.totalSuccessRate([RequestBucket(time: "idle", success: 0, failed: 0)]))
    }

    func testCountdownFormatting() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaMath.countdown(to: now.addingTimeInterval(59 * 60), now: now), "59m")
        XCTAssertEqual(QuotaMath.countdown(to: now.addingTimeInterval(125 * 60), now: now), "2h 5m")
        XCTAssertEqual(QuotaMath.countdown(to: now.addingTimeInterval(51 * 60 * 60), now: now), "2d 3h")
    }

    func testPlanWeightsAndWeightedRemaining() {
        XCTAssertEqual(QuotaMath.planDisplayName("self_serve_business_prolite"), "Premium")
        XCTAssertEqual(QuotaMath.planDisplayName("pro_lite"), "ProLite")
        for plan in ["self_serve_business_prolite", "Premium", "ProLite", "pro_lite", "pro-lite"] {
            XCTAssertTrue(QuotaMath.isProLitePlan(plan))
            XCTAssertEqual(QuotaMath.planWeight(plan), 5)
        }
        XCTAssertEqual(QuotaMath.planWeight("Plus"), 1)
        XCTAssertEqual(QuotaMath.planWeight("Pro 5x"), 5)
        XCTAssertEqual(QuotaMath.planWeight("pro5x"), 5)
        XCTAssertEqual(QuotaMath.planWeight("pro_20x"), 20)
        XCTAssertEqual(QuotaMath.planWeight("Pro 20X"), 20)
        XCTAssertEqual(QuotaMath.planWeight("unknown"), 1)
        XCTAssertEqual(
            QuotaMath.weightedAverageRemaining([
                (remaining: 100, plan: "Plus"),
                (remaining: 0, plan: "Pro 20x"),
            ])!,
            100.0 / 21.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            QuotaMath.weightedAverageRemaining([
                (remaining: 100, plan: "Plus"),
                (remaining: 0, plan: "Pro 5x"),
            ])!,
            100.0 / 6.0,
            accuracy: 0.0001
        )
    }

    func testPluginSettingsUsesCPAKeys() throws {
        let data = try JSONEncoder().encode(PluginSettings())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["remaining_threshold_percent"] as? Double, 10)
        XCTAssertEqual(object["idle_refresh_interval"] as? String, "1h")
        XCTAssertNotNil(object["account_overrides"])
    }

    func testParsesRFC3339Nano() {
        XCTAssertNotNil(QuotaDate.parse("2026-09-08T12:19:15.123456789+08:00"))
        XCTAssertNotNil(QuotaDate.parse("2026-09-08T04:19:15Z"))
    }

}
