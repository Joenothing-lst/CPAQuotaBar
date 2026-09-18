import Foundation

/// CPA 管理的账号池服务类型（支持 OpenAI、Gemini、Claude）
public enum AccountPoolType: String, CaseIterable, Codable, Sendable, Identifiable {
    case openai = "openai"
    case gemini = "gemini"
    case claude = "claude"

    public static let codex = AccountPoolType.openai
    public static let antigravity = AccountPoolType.gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    public init?(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai", "codex":
            self = .openai
        case "gemini", "antigravity":
            self = .gemini
        case "claude":
            self = .claude
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let matched = AccountPoolType(rawValue: raw) {
            self = matched
        } else {
            self = .openai
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias CodexSummary = CPASummary

public struct CPASummary: Codable, Sendable {
    public let generatedAt: String
    public let config: RuntimeConfig
    public let totalAccounts: Int
    public let knownAccounts: Int
    public let unknownAccounts: Int
    public let heldAccounts: Int
    public let primary: WindowSummary
    public let secondary: WindowSummary
    public let recentRequests: [RequestBucket]
    public let accounts: [Account]
    public let refreshing: Bool
    public let lastScanAt: String?
    public let lastScanError: String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case config
        case totalAccounts = "total_accounts"
        case knownAccounts = "known_accounts"
        case unknownAccounts = "unknown_accounts"
        case heldAccounts = "held_accounts"
        case primary, secondary
        case recentRequests = "recent_requests"
        case accounts, refreshing
        case lastScanAt = "last_scan_at"
        case lastScanError = "last_scan_error"
    }

    public init(
        generatedAt: String,
        config: RuntimeConfig,
        totalAccounts: Int,
        knownAccounts: Int,
        unknownAccounts: Int,
        heldAccounts: Int,
        primary: WindowSummary,
        secondary: WindowSummary,
        recentRequests: [RequestBucket],
        accounts: [Account],
        refreshing: Bool = false,
        lastScanAt: String?,
        lastScanError: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.config = config
        self.totalAccounts = totalAccounts
        self.knownAccounts = knownAccounts
        self.unknownAccounts = unknownAccounts
        self.heldAccounts = heldAccounts
        self.primary = primary
        self.secondary = secondary
        self.recentRequests = recentRequests
        self.accounts = accounts
        self.refreshing = refreshing
        self.lastScanAt = lastScanAt
        self.lastScanError = lastScanError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        config = try container.decode(RuntimeConfig.self, forKey: .config)
        totalAccounts = try container.decode(Int.self, forKey: .totalAccounts)
        knownAccounts = try container.decode(Int.self, forKey: .knownAccounts)
        unknownAccounts = try container.decode(Int.self, forKey: .unknownAccounts)
        heldAccounts = try container.decode(Int.self, forKey: .heldAccounts)
        primary = try container.decode(WindowSummary.self, forKey: .primary)
        secondary = try container.decode(WindowSummary.self, forKey: .secondary)
        recentRequests = try container.decodeIfPresent([RequestBucket].self, forKey: .recentRequests) ?? []
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        refreshing = try container.decode(Bool.self, forKey: .refreshing)
        lastScanAt = try container.decodeIfPresent(String.self, forKey: .lastScanAt)
        lastScanError = try container.decodeIfPresent(String.self, forKey: .lastScanError)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(config, forKey: .config)
        try container.encode(totalAccounts, forKey: .totalAccounts)
        try container.encode(knownAccounts, forKey: .knownAccounts)
        try container.encode(unknownAccounts, forKey: .unknownAccounts)
        try container.encode(heldAccounts, forKey: .heldAccounts)
        try container.encode(primary, forKey: .primary)
        try container.encode(secondary, forKey: .secondary)
        try container.encode(recentRequests, forKey: .recentRequests)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(refreshing, forKey: .refreshing)
        try container.encodeIfPresent(lastScanAt, forKey: .lastScanAt)
        try container.encodeIfPresent(lastScanError, forKey: .lastScanError)
    }
}

extension CPASummary {
    public func recalculatingQuota(now: Date = Date()) -> CPASummary {
        CPASummary(
            generatedAt: generatedAt,
            config: config,
            totalAccounts: totalAccounts,
            knownAccounts: knownAccounts,
            unknownAccounts: unknownAccounts,
            heldAccounts: heldAccounts,
            primary: QuotaMath.summarizeWindow(accounts: accounts, key: "primary", now: now),
            secondary: QuotaMath.summarizeWindow(accounts: accounts, key: "secondary", now: now),
            recentRequests: recentRequests,
            accounts: accounts,
            refreshing: refreshing,
            lastScanAt: lastScanAt,
            lastScanError: lastScanError
        )
    }
}

public struct RuntimeConfig: Codable, Sendable {
    public let remainingThresholdPercent: Double
    public let accountOverrides: [String: Double]

    enum CodingKeys: String, CodingKey {
        case remainingThresholdPercent = "remaining_threshold_percent"
        case accountOverrides = "account_overrides"
    }


    public init(remainingThresholdPercent: Double, accountOverrides: [String: Double]) {
        self.remainingThresholdPercent = remainingThresholdPercent
        self.accountOverrides = accountOverrides
    }
}

public struct WindowSummary: Codable, Sendable {
    public let knownAccounts: Int
    public let averageRemainingPercent: Double
    public let effectiveResetAt: String?
    public let resetProgressPercent: Double?

    enum CodingKeys: String, CodingKey {
        case knownAccounts = "known_accounts"
        case averageRemainingPercent = "average_remaining_percent"
        case effectiveResetAt = "effective_reset_at"
        case resetProgressPercent = "reset_progress_percent"
    }

    public init(
        knownAccounts: Int,
        averageRemainingPercent: Double,
        effectiveResetAt: String?,
        resetProgressPercent: Double?
    ) {
        self.knownAccounts = knownAccounts
        self.averageRemainingPercent = averageRemainingPercent
        self.effectiveResetAt = effectiveResetAt
        self.resetProgressPercent = resetProgressPercent
    }

    public var remaining: Double? {
        knownAccounts > 0 ? averageRemainingPercent.clampedPercent : nil
    }

    public var resetDate: Date? { effectiveResetAt.flatMap(QuotaDate.parse) }
}

public struct Account: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let label: String?
    public let email: String?
    public let authType: String?
    public let channel: String?
    public let planType: String?
    public let subscriptionUntil: String?
    public let credentialExpires: String?
    public let hostDisabled: Bool
    public let windows: [String: QuotaWindow]
    public let recentRequests: [RequestBucket]
    public let thresholdPercent: Double
    public let held: Bool
    public let unknown: Bool
    public let stale: Bool
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, label, email, channel, windows, held, unknown, stale
        case authType = "auth_type"
        case planType = "plan_type"
        case subscriptionUntil = "subscription_until"
        case credentialExpires = "credential_expires"
        case hostDisabled = "host_disabled"
        case recentRequests = "recent_requests"
        case thresholdPercent = "threshold_percent"
        case lastError = "last_error"
    }

    public init(
        id: String,
        name: String?,
        label: String?,
        email: String?,
        authType: String?,
        channel: String? = nil,
        planType: String?,
        subscriptionUntil: String?,
        credentialExpires: String?,
        hostDisabled: Bool,
        windows: [String: QuotaWindow],
        recentRequests: [RequestBucket],
        thresholdPercent: Double,
        held: Bool,
        unknown: Bool,
        stale: Bool,
        lastError: String?
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.email = email
        self.authType = authType
        self.channel = channel
        self.planType = planType
        self.subscriptionUntil = subscriptionUntil
        self.credentialExpires = credentialExpires
        self.hostDisabled = hostDisabled
        self.windows = QuotaWindow.normalized(windows)
        self.recentRequests = recentRequests
        self.thresholdPercent = thresholdPercent
        self.held = held
        self.unknown = unknown
        self.stale = stale
        self.lastError = lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        authType = try container.decodeIfPresent(String.self, forKey: .authType)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        subscriptionUntil = try container.decodeIfPresent(String.self, forKey: .subscriptionUntil)
        credentialExpires = try container.decodeIfPresent(String.self, forKey: .credentialExpires)
        hostDisabled = try container.decodeIfPresent(Bool.self, forKey: .hostDisabled) ?? false
        windows = QuotaWindow.normalized(try container.decodeIfPresent([String: QuotaWindow].self, forKey: .windows) ?? [:])
        recentRequests = try container.decodeIfPresent([RequestBucket].self, forKey: .recentRequests) ?? []
        thresholdPercent = try container.decodeIfPresent(Double.self, forKey: .thresholdPercent) ?? 0
        held = try container.decodeIfPresent(Bool.self, forKey: .held) ?? false
        unknown = try container.decodeIfPresent(Bool.self, forKey: .unknown) ?? false
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(authType, forKey: .authType)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(subscriptionUntil, forKey: .subscriptionUntil)
        try container.encodeIfPresent(credentialExpires, forKey: .credentialExpires)
        try container.encode(hostDisabled, forKey: .hostDisabled)
        try container.encode(windows, forKey: .windows)
        try container.encode(recentRequests, forKey: .recentRequests)
        try container.encode(thresholdPercent, forKey: .thresholdPercent)
        try container.encode(held, forKey: .held)
        try container.encode(unknown, forKey: .unknown)
        try container.encode(stale, forKey: .stale)
        try container.encodeIfPresent(lastError, forKey: .lastError)
    }

    public var displayName: String { label ?? email ?? name ?? id }
    public var validityDate: Date? {
        (subscriptionUntil ?? credentialExpires).flatMap(QuotaDate.parse)
    }
    public var primary: QuotaWindow? { windows["primary"] }
    public var secondary: QuotaWindow? { windows["secondary"] }
}

public struct QuotaWindow: Codable, Sendable {
    public let name: String
    public let usedPercent: Double
    public let resetAt: String?
    public let windowSeconds: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case windowSeconds = "window_seconds"
    }

    public init(name: String, usedPercent: Double, resetAt: String?, windowSeconds: Int64?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
    }

    /// API primary/secondary positions do not identify the quota period.
    /// Normalize both live responses and older cached accounts by duration.
    static func normalized(_ windows: [String: QuotaWindow]) -> [String: QuotaWindow] {
        var result: [String: QuotaWindow] = [:]
        for key in windows.keys.sorted() {
            guard let window = windows[key] else { continue }
            let destination: String
            switch window.windowSeconds {
            case 5 * 3600: destination = "primary"
            case 7 * 24 * 3600: destination = "secondary"
            default: destination = key
            }
            // Prefer the native slot if an upstream response duplicates a period.
            if result[destination] == nil || key == destination {
                result[destination] = QuotaWindow(
                    name: destination,
                    usedPercent: window.usedPercent,
                    resetAt: window.resetAt,
                    windowSeconds: window.windowSeconds
                )
            }
        }
        return result
    }

    public var remaining: Double { (100 - usedPercent).clampedPercent }
    public var resetDate: Date? { resetAt.flatMap(QuotaDate.parse) }

    public func resetProgress(now: Date = Date()) -> Double? {
        guard let resetDate, let windowSeconds, windowSeconds > 0 else { return nil }
        return (resetDate.timeIntervalSince(now) / Double(windowSeconds) * 100).clampedPercent
    }
}

public struct RequestBucket: Codable, Sendable, Equatable {
    public let time: String
    public let success: Int64
    public let failed: Int64

    enum CodingKeys: String, CodingKey {
        case time, success, failed
    }

    public init(time: String, success: Int64, failed: Int64) {
        self.time = time
        self.success = success
        self.failed = failed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(success, forKey: .success)
        try container.encode(failed, forKey: .failed)
    }

    public var total: Int64 { success + failed }
    public var successRate: Double? {
        total > 0 ? Double(success) / Double(total) * 100 : nil
    }
}

public struct PluginSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var priority: Int
    public var remainingThresholdPercent: Double
    public var refreshInterval: String
    public var idleRefreshInterval: String
    public var idleAfter: String
    public var staleAfter: String
    public var unknownQuotaPolicy: String
    public var selectionStrategy: String
    public var accountOverrides: [String: Double]

    public init(
        enabled: Bool = true,
        priority: Int = 200,
        remainingThresholdPercent: Double = 10,
        refreshInterval: String = "1m",
        idleRefreshInterval: String = "1h",
        idleAfter: String = "5m",
        staleAfter: String = "20m",
        unknownQuotaPolicy: String = "allow",
        selectionStrategy: String = "round-robin",
        accountOverrides: [String: Double] = [:]
    ) {
        self.enabled = enabled
        self.priority = priority
        self.remainingThresholdPercent = remainingThresholdPercent
        self.refreshInterval = refreshInterval
        self.idleRefreshInterval = idleRefreshInterval
        self.idleAfter = idleAfter
        self.staleAfter = staleAfter
        self.unknownQuotaPolicy = unknownQuotaPolicy
        self.selectionStrategy = selectionStrategy
        self.accountOverrides = accountOverrides
    }

    enum CodingKeys: String, CodingKey {
        case enabled, priority
        case remainingThresholdPercent = "remaining_threshold_percent"
        case refreshInterval = "refresh_interval"
        case idleRefreshInterval = "idle_refresh_interval"
        case idleAfter = "idle_after"
        case staleAfter = "stale_after"
        case unknownQuotaPolicy = "unknown_quota_policy"
        case selectionStrategy = "selection_strategy"
        case accountOverrides = "account_overrides"
    }
}

public enum QuotaMath {
    public static func planDisplayName(_ plan: String) -> String {
        switch normalizedPlan(plan) {
        case "selfservebusinessprolite", "premium": return "Premium"
        case "prolite": return "ProLite"
        default: return plan.prefix(1).uppercased() + String(plan.dropFirst()).lowercased()
        }
    }

    /// Premium business seats share the ProLite capacity and badge style.
    public static func isProLitePlan(_ plan: String?) -> Bool {
        ["prolite", "selfservebusinessprolite", "premium"].contains(normalizedPlan(plan))
    }

    private static func normalizedPlan(_ plan: String?) -> String {
        (plan ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Returns the relative quota capacity for a Codex plan.
    /// Unknown or missing plans use the Plus capacity as a safe default.
    public static func planWeight(_ plan: String?) -> Double {
        let normalized = normalizedPlan(plan)
        if isProLitePlan(plan) { return 5 }
        if normalized.contains("20x") || normalized.contains("pro20") { return 20 }
        if normalized.contains("5x") || normalized.contains("pro5") { return 5 }
        return 1
    }

    /// Computes a remaining-quota average weighted by each account's plan capacity.
    public static func weightedAverageRemaining(_ samples: [(remaining: Double, plan: String?)]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let weightedTotal = samples.reduce(0.0) { total, sample in
            total + sample.remaining * planWeight(sample.plan)
        }
        let totalWeight = samples.reduce(0.0) { total, sample in
            total + planWeight(sample.plan)
        }
        guard totalWeight > 0 else { return nil }
        return weightedTotal / totalWeight
    }

    public static func totalSuccessRate(_ buckets: [RequestBucket]) -> Double? {
        let success = buckets.reduce(Int64(0)) { $0 + $1.success }
        let total = buckets.reduce(Int64(0)) { $0 + $1.total }
        return total > 0 ? Double(success) / Double(total) * 100 : nil
    }

    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let minuteRemainder = minutes % 60
        if hours < 24 {
            return minuteRemainder == 0 ? "\(hours)h" : "\(hours)h \(minuteRemainder)m"
        }
        let days = hours / 24
        let hourRemainder = hours % 24
        return hourRemainder == 0 ? "\(days)d" : "\(days)d \(hourRemainder)h"
    }
}

public enum QuotaDate {
    public static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }


    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Double {
    var clampedPercent: Double { min(100, max(0, self)) }
}
