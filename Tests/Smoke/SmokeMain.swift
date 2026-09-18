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

        try! quotaRegressionTests()
        print("CPAQuotaCore smoke tests passed")
    }

    static func quotaRegressionTests() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let weeklyData = Data("""
        {"plan_type":"self_serve_business_prolite","rate_limit":{
            "primary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_after_seconds":600000},
            "secondary_window":null
        }}
        """.utf8)
        let weekly = try parseOpenAIUsage(weeklyData, now: now)
        precondition(weekly.windows["primary"] == nil, "weekly quota must not appear as 5h")
        precondition(weekly.windows["secondary"]?.remaining == 97)
        precondition(weekly.windows["secondary"]?.windowSeconds == 604800)
        precondition(weekly.windows["secondary"]?.resetDate == now.addingTimeInterval(600000))
        precondition(QuotaMath.planDisplayName(weekly.planType!) == "Premium")
        precondition(QuotaMath.planDisplayName("plus") == "Plus")
        precondition(QuotaMath.planDisplayName("pro_lite") == "ProLite")
        for alias in ["self_serve_business_prolite", "Premium", "ProLite", "pro_lite", "pro-lite"] {
            precondition(QuotaMath.isProLitePlan(alias))
            precondition(QuotaMath.planWeight(alias) == 5)
        }
        precondition(QuotaMath.planWeight("Pro 20x") == 20)
        precondition(QuotaMath.planWeight("Plus") == 1)
        precondition(QuotaMath.planWeight("unknown") == 1)

        let plus = try parseOpenAIUsage(Data("""
        {"planType":"plus","rateLimit":{
            "primaryWindow":{"usedPercent":0,"limitWindowSeconds":18000,"resetAfterSeconds":18000},
            "secondaryWindow":{"usedPercent":52,"limitWindowSeconds":604800,"resetAfterSeconds":86000}
        }}
        """.utf8), now: now)
        precondition(plus.windows["primary"]?.remaining == 100)
        precondition(plus.windows["secondary"]?.remaining == 48)

        let legacy = try parseOpenAIUsage(Data("""
        {"rate_limit":{"primary_window":{"used_percent":10},"secondary_window":{"used_percent":20}}}
        """.utf8), now: now)
        precondition(legacy.windows["primary"]?.remaining == 90)
        precondition(legacy.windows["secondary"]?.remaining == 80)

        func account(_ id: String, disabled: Bool = false, held: Bool = false,
                     windows: [String: QuotaWindow], plan: String = "plus") -> Account {
            Account(id: id, name: nil, label: nil, email: nil, authType: nil,
                    planType: plan, subscriptionUntil: nil, credentialExpires: nil,
                    hostDisabled: disabled, windows: windows, recentRequests: [],
                    thresholdPercent: 10, held: held, unknown: false, stale: false, lastError: nil)
        }
        let active = account("business", windows: weekly.windows, plan: weekly.planType!)
        let disabled = account("disabled", disabled: true, windows: plus.windows, plan: "pro_20x")
        let held = account("held", held: true, windows: plus.windows)
        let accounts = [active, disabled, held]
        let primary = QuotaMath.summarizeWindow(accounts: accounts, key: "primary", now: now)
        let secondary = QuotaMath.summarizeWindow(accounts: accounts, key: "secondary", now: now)
        precondition(primary.remaining == nil && primary.resetDate == nil)
        precondition(secondary.knownAccounts == 1 && secondary.remaining == 97)
        precondition(secondary.resetDate == active.secondary?.resetDate, "disabled resets must be excluded")
        precondition(secondary.resetProgressPercent == active.secondary?.resetProgress(now: now))
        let allDisabled = QuotaMath.summarizeWindow(accounts: [disabled, held], key: "secondary", now: now)
        precondition(allDisabled.remaining == nil && allDisabled.resetDate == nil)
        let enabledPlus = account("plus", windows: plus.windows)
        let mixed = QuotaMath.summarizeWindow(accounts: [active, enabledPlus], key: "secondary", now: now)
        precondition(mixed.knownAccounts == 2)
        precondition(abs(mixed.remaining! - (97 * 5.0 + 48) / 6) < 0.0001)
        precondition(QuotaMath.summarizeWindow(accounts: [active, enabledPlus], key: "primary", now: now).remaining == 100)

        // Migrate the screenshot's old cached representation: a weekly primary
        // window and an aggregate that includes disabled Plus accounts.
        let cachedAccount = Data("""
        {"id":"business","windows":{"primary":{"name":"primary","used_percent":3,
        "window_seconds":604800,"reset_at":"2026-10-17T00:00:00Z"}}}
        """.utf8)
        let restored = try JSONDecoder().decode(Account.self, from: cachedAccount)
        precondition(restored.primary == nil && restored.secondary?.remaining == 97)
        precondition(restored.secondary?.name == "secondary")
        let summary = CPASummary(
            generatedAt: QuotaDate.string(from: now),
            config: RuntimeConfig(remainingThresholdPercent: 10, accountOverrides: [:]),
            totalAccounts: 2, knownAccounts: 2, unknownAccounts: 0, heldAccounts: 1,
            primary: WindowSummary(knownAccounts: 2, averageRemainingPercent: 99,
                                   effectiveResetAt: nil, resetProgressPercent: nil),
            secondary: WindowSummary(knownAccounts: 1, averageRemainingPercent: 48,
                                     effectiveResetAt: nil, resetProgressPercent: nil),
            recentRequests: [], accounts: [restored, disabled], lastScanAt: nil
        )
        let cached = try JSONDecoder().decode(CPASummary.self, from: JSONEncoder().encode(summary))
            .recalculatingQuota(now: now)
        precondition(cached.primary.remaining == nil && cached.secondary.remaining == 97)
        precondition(cached.totalAccounts == 2 && cached.heldAccounts == 1)
    }

}
