import Foundation

@main
struct CoreSmokeTests {
    static func main() {
        let buckets = [
            RequestBucket(time: "10:00-10:10", success: 8, failed: 2),
            RequestBucket(time: "10:10-10:20", success: 2, failed: 0),
        ]
        guard let rate = QuotaMath.totalSuccessRate(buckets), abs(rate - 83.3333) < 0.01 else {
            fatalError("total success rate failed")
        }
        guard QuotaMath.totalSuccessRate([RequestBucket(time: "idle", success: 0, failed: 0)]) == nil else {
            fatalError("idle success rate failed")
        }
        guard abs(QuotaMath.weightedAverageRemaining([
            (remaining: 100, plan: "Plus"),
            (remaining: 0, plan: "Pro 20x"),
        ])! - (100.0 / 21.0)) < 0.0001 else {
            fatalError("weighted quota average failed")
        }
        let now = Date(timeIntervalSince1970: 1_000)
        guard QuotaMath.countdown(to: now.addingTimeInterval(125 * 60), now: now) == "2h 5m" else {
            fatalError("countdown failed")
        }
        guard QuotaDate.parse("2026-09-08T12:19:15.123456789+08:00") != nil else {
            fatalError("RFC3339Nano parsing failed")
        }
        let encoded = try! JSONEncoder().encode(PluginSettings())
        let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        guard object["idle_refresh_interval"] as? String == "1h" else {
            fatalError("CPA config encoding failed")
        }
        let window = WindowSummary(
            knownAccounts: 2,
            averageRemainingPercent: 63,
            effectiveResetAt: "2026-09-10T18:00:00+08:00",
            resetProgressPercent: 40
        )
        let restored = try! JSONDecoder().decode(
            WindowSummary.self,
            from: JSONEncoder().encode(window)
        )
        guard restored.remaining == 63, restored.resetProgressPercent == 40 else {
            fatalError("quota window cache encoding failed")
        }

        // 验证 AccountPoolType 兼容性
        guard AccountPoolType(rawValue: "openai") == .openai,
              AccountPoolType(rawValue: "gemini") == .gemini,
              AccountPoolType(rawValue: "claude") == .claude,
              AccountPoolType(rawValue: "codex") == .openai,
              AccountPoolType(rawValue: "antigravity") == .gemini else {
            fatalError("AccountPoolType mapping failed")
        }

        let decodedPool = try! JSONDecoder().decode(AccountPoolType.self, from: "\"antigravity\"".data(using: .utf8)!)
        guard decodedPool == .gemini else {
            fatalError("AccountPoolType JSON backward compatibility failed")
        }

        print("CPAQuotaCore smoke tests passed")
    }
}
