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
