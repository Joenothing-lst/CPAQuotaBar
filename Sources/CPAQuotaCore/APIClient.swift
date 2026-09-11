import Foundation

public enum CPAError: LocalizedError, Sendable {
    case invalidAddress
    case missingKey
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "CPA 地址无效"
        case .missingKey: return "请在设置中填写 Management Key"
        case let .http(code, message): return message.isEmpty ? "CPA 返回 HTTP \(code)" : "HTTP \(code) · \(message)"
        case .invalidResponse: return "CPA 返回了无法识别的数据"
        }
    }
}

public struct NativeFetchResult: Sendable {
    public let summary: CPASummary
    public let managedHolds: [String: Date]
    public let activity: CPAActivitySnapshot
}

public struct CPAActivitySnapshot: Equatable, Sendable {
    public let success: Int64
    public let failed: Int64
    public let roster: [String]

    public init(success: Int64, failed: Int64, roster: [String]) {
        self.success = success
        self.failed = failed
        self.roster = roster
    }
}

public struct CPAClient: Sendable {
    public let address: String
    public let managementKey: String

    public init(address: String, managementKey: String) {
        self.address = address
        self.managementKey = managementKey
    }

    /// Builds the dashboard from CPA's native management API. No plugin route
    /// or plugin-owned state is used.
    public func fetchStatus(
        pool: AccountPoolType = .codex,
        settings: PluginSettings,
        managedHolds initialHolds: [String: Date] = [:],
        applyPolicy: Bool
    ) async throws -> NativeFetchResult {
        let now = Date()
        let allFiles = try await fetchAuthFiles()
        let allPresentIDs = Set(allFiles.map(\.stableName))
        var holds = initialHolds.filter { allPresentIDs.contains($0.key) }
        var files = allFiles.filter { $0.matches(pool: pool) }
        var policyErrors: [String] = []

        // Only accounts disabled by this app enter managedHolds. Consequently,
        // a manual disable in CPA can never be undone here.
        for index in files.indices {
            let id = files[index].stableName
            guard let releaseAt = holds[id], !settings.enabled || releaseAt <= now else { continue }
            do {
                if files[index].disabled {
                    try await setAuthDisabled(name: id, disabled: false)
                }
                files[index].disabled = false
                holds.removeValue(forKey: id)
            } catch {
                policyErrors.append("\(files[index].displayName): \(error.localizedDescription)")
            }
        }

        var accounts = await withTaskGroup(of: Account.self, returning: [Account].self) { group in
            for file in files {
                group.addTask {
                    await account(from: file, pool: pool, settings: settings, now: now)
                }
            }
            var values: [Account] = []
            for await account in group { values.append(account) }
            return values
        }

        if applyPolicy && settings.enabled {
            for index in accounts.indices where !accounts[index].hostDisabled {
                guard let releaseAt = triggeredRelease(for: accounts[index], now: now) else { continue }
                do {
                    try await setAuthDisabled(name: accounts[index].id, disabled: true)
                    holds[accounts[index].id] = releaseAt
                    accounts[index] = copy(accounts[index], disabled: true)
                } catch {
                    policyErrors.append("\(accounts[index].displayName): \(error.localizedDescription)")
                }
            }
        }

        accounts.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return NativeFetchResult(
            summary: makeSummary(
                accounts: accounts,
                settings: settings,
                now: now,
                lastError: policyErrors.isEmpty ? nil : policyErrors.joined(separator: "；")
            ),
            managedHolds: holds,
            activity: activitySnapshot(files)
        )
    }

    /// A lightweight activity probe. It never queries ChatGPT quota and is
    /// cheap enough to run once a minute while the menu panel is closed.
    public func fetchActivitySnapshot(pool: AccountPoolType = .codex) async throws -> CPAActivitySnapshot {
        activitySnapshot(try await fetchAuthFiles().filter { $0.matches(pool: pool) })
    }

    /// Tests CPA connectivity and authentication without querying ChatGPT quota.
    public func testConnectivity(pool: AccountPoolType = .codex) async throws -> Int {
        let files = try await fetchAuthFiles().filter { $0.matches(pool: pool) }
        return files.count
    }

    private func fetchAuthFiles() async throws -> [NativeAuthFile] {
        let data = try await request(path: "/v0/management/auth-files")
        do { return try JSONDecoder().decode(NativeAuthFilesResponse.self, from: data).files }
        catch { throw CPAError.invalidResponse }
    }

    private func setAuthDisabled(name: String, disabled: Bool) async throws {
        let body = try JSONEncoder().encode(AuthStatusRequest(name: name, disabled: disabled))
        _ = try await request(path: "/v0/management/auth-files/status", method: "PATCH", body: body)
    }

    private func account(
        from file: NativeAuthFile,
        pool: AccountPoolType,
        settings: PluginSettings,
        now: Date
    ) async -> Account {
        let threshold = threshold(for: file, settings: settings)
        let rawType = (file.provider ?? file.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAntigravity = rawType == "antigravity"
        // 渠道标签：仅来自 Antigravity 渠道的账号标记为 "Antigravity"；官方 Claude OAuth 与 OpenAI 账号绝不展示该渠道标签
        let channelTag: String? = isAntigravity ? "Antigravity" : nil

        do {
            let parsed: ParsedUsage
            var resolvedPlan: String? = nil

            if isAntigravity {
                let data = try await fetchAntigravityQuota(for: file)
                parsed = try parseAntigravityUsage(data, pool: pool, now: now)
                let tier = await fetchAntigravityTier(for: file)
                resolvedPlan = tier ?? "Pro"
            } else if rawType == "claude" {
                let data = try await fetchClaudeQuota(for: file)
                parsed = try parseClaudeUsage(data, now: now)
                resolvedPlan = parsed.planType ?? file.idToken?.planType
            } else {
                let data = try await fetchCodexQuota(for: file)
                parsed = try parseOpenAIUsage(data, now: now)
                resolvedPlan = parsed.planType ?? file.idToken?.planType
            }

            return Account(
                id: file.stableName,
                name: file.name,
                label: file.label,
                email: file.email ?? file.account,
                authType: file.accountType,
                channel: channelTag,
                planType: resolvedPlan,
                subscriptionUntil: file.idToken?.subscriptionUntil,
                credentialExpires: nil,
                hostDisabled: file.disabled,
                windows: parsed.windows,
                recentRequests: file.recentRequests,
                thresholdPercent: threshold,
                held: file.disabled,
                unknown: parsed.windows.isEmpty,
                stale: false,
                lastError: nil
            )
        } catch {
            return Account(
                id: file.stableName,
                name: file.name,
                label: file.label,
                email: file.email ?? file.account,
                authType: file.accountType,
                channel: channelTag,
                planType: isAntigravity ? "Pro" : file.idToken?.planType,
                subscriptionUntil: file.idToken?.subscriptionUntil,
                credentialExpires: nil,
                hostDisabled: file.disabled,
                windows: [:],
                recentRequests: file.recentRequests,
                thresholdPercent: threshold,
                held: file.disabled,
                unknown: true,
                stale: false,
                lastError: error.localizedDescription
            )
        }
    }

    private func fetchCodexQuota(for file: NativeAuthFile) async throws -> Data {
        guard !file.authIndex.isEmpty else { throw CPAError.invalidResponse }
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "CPAQuotaBar/0.3",
        ]
        if let accountID = file.idToken?.accountID, !accountID.isEmpty {
            headers["Chatgpt-Account-Id"] = accountID
        }
        let payload = NativeAPICallRequest(
            authIndex: file.authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers
        )
        return try await executeAPICall(payload)
    }

    private func fetchAntigravityQuota(for file: NativeAuthFile) async throws -> Data {
        guard !file.authIndex.isEmpty else { throw CPAError.invalidResponse }
        let projectID = file.projectID ?? ""
        let bodyData = "{\"project\":\"\(projectID)\"}"
        let endpoints = [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ]
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)",
        ]

        var lastError: Error?
        for endpoint in endpoints {
            let payload = NativeAPICallRequest(
                authIndex: file.authIndex,
                method: "POST",
                url: endpoint,
                header: headers,
                data: bodyData
            )
            do {
                let data = try await executeAPICall(payload)
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? CPAError.invalidResponse
    }

    private func fetchClaudeQuota(for file: NativeAuthFile) async throws -> Data {
        guard !file.authIndex.isEmpty else { throw CPAError.invalidResponse }
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
        ]
        let payload = NativeAPICallRequest(
            authIndex: file.authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/usage",
            header: headers
        )
        return try await executeAPICall(payload)
    }

    private func fetchAntigravityTier(for file: NativeAuthFile) async -> String? {
        guard !file.authIndex.isEmpty else { return nil }
        let payload = NativeAPICallRequest(
            authIndex: file.authIndex,
            method: "POST",
            url: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            header: [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"
            ],
            data: "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}"
        )
        do {
            let data = try await executeAPICall(payload)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let paidTier = root["paidTier"] as? [String: Any] ?? root["paid_tier"] as? [String: Any] {
                let id = (paidTier["id"] as? String ?? "").lowercased()
                let name = paidTier["name"] as? String ?? ""
                if id.contains("ultra-lite") { return "Ultra-Lite" }
                if id.contains("ultra") { return "Ultra" }
                if id.contains("pro") || name.lowercased().contains("pro") { return "Pro" }
                if !name.isEmpty { return name }
            }
            if let currentTier = root["currentTier"] as? [String: Any] ?? root["current_tier"] as? [String: Any] {
                let id = (currentTier["id"] as? String ?? "").lowercased()
                if id.contains("free") { return "Free" }
                if id.contains("pro") { return "Pro" }
                if id.contains("ultra") { return "Ultra" }
                if let name = currentTier["name"] as? String, !name.isEmpty, name.lowercased() != "antigravity" {
                    return name
                }
            }
            return "Free"
        } catch {
            return nil
        }
    }

    private func executeAPICall(_ payload: NativeAPICallRequest) async throws -> Data {
        let outer = try await request(
            path: "/v0/management/api-call",
            method: "POST",
            body: try JSONEncoder().encode(payload)
        )
        guard let object = try JSONSerialization.jsonObject(with: outer) as? [String: Any],
              let statusCode = number(object["status_code"]).map(Int.init) else {
            throw CPAError.invalidResponse
        }
        let inner: Data
        if let text = object["body"] as? String {
            inner = Data(text.utf8)
        } else if let body = object["body"], JSONSerialization.isValidJSONObject(body) {
            inner = try JSONSerialization.data(withJSONObject: body)
        } else {
            throw CPAError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw CPAError.http(statusCode, responseMessage(inner))
        }
        return inner
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CPAError.missingKey
        }
        var target = normalizedAddress
        if !target.lowercased().hasPrefix("http://") && !target.lowercased().hasPrefix("https://") {
            target = "http://" + target
        }
        guard var components = URLComponents(string: target),
              components.scheme == "http" || components.scheme == "https" else {
            throw CPAError.invalidAddress
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CPAError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CPAError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw CPAError.http(response.statusCode, responseMessage(data))
        }
        return data
    }

    private var normalizedAddress: String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

private struct NativeAuthFilesResponse: Decodable, Sendable {
    let files: [NativeAuthFile]
}

private struct NativeAuthFile: Decodable, Sendable {
    let id: String?
    let name: String?
    let label: String?
    let account: String?
    let email: String?
    let provider: String?
    let type: String?
    let projectID: String?
    let accountType: String?
    let authIndex: String
    var disabled: Bool
    let recentRequests: [RequestBucket]
    let idToken: AuthTokenMetadata?
    let success: Int64
    let failed: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, label, account, email, provider, type, disabled, success, failed
        case projectID = "project_id"
        case accountType = "account_type"
        case authIndex = "auth_index"
        case recentRequests = "recent_requests"
        case idToken = "id_token"
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id)
        name = try box.decodeIfPresent(String.self, forKey: .name)
        label = try box.decodeIfPresent(String.self, forKey: .label)
        account = try box.decodeIfPresent(String.self, forKey: .account)
        email = try box.decodeIfPresent(String.self, forKey: .email)
        provider = try box.decodeIfPresent(String.self, forKey: .provider)
        type = try box.decodeIfPresent(String.self, forKey: .type)
        projectID = try box.decodeIfPresent(String.self, forKey: .projectID)
        accountType = try box.decodeIfPresent(String.self, forKey: .accountType)
        authIndex = try box.decodeIfPresent(String.self, forKey: .authIndex) ?? ""
        disabled = try box.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        recentRequests = try box.decodeIfPresent([RequestBucket].self, forKey: .recentRequests) ?? []
        idToken = try box.decodeIfPresent(AuthTokenMetadata.self, forKey: .idToken)
        success = try box.decodeIfPresent(Int64.self, forKey: .success)
            ?? recentRequests.reduce(0) { $0 + $1.success }
        failed = try box.decodeIfPresent(Int64.self, forKey: .failed)
            ?? recentRequests.reduce(0) { $0 + $1.failed }
    }

    var poolType: AccountPoolType? {
        let raw = (provider ?? type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "codex" || raw == "openai" { return .openai }
        if raw == "antigravity" || raw == "gemini" { return .gemini }
        if raw == "claude" { return .claude }
        return nil
    }

    func matches(pool: AccountPoolType) -> Bool {
        let raw = (provider ?? type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch pool {
        case .openai:
            return raw == "codex" || raw == "openai"
        case .gemini:
            return raw == "antigravity" || raw == "gemini"
        case .claude:
            return raw == "claude" || raw == "antigravity"
        }
    }

    var isCodex: Bool {
        matches(pool: .openai)
    }
    var stableName: String { name ?? id ?? authIndex }
    var displayName: String { label ?? email ?? account ?? stableName }
}

private func activitySnapshot(_ files: [NativeAuthFile]) -> CPAActivitySnapshot {
    CPAActivitySnapshot(
        success: files.reduce(0) { $0 + $1.success },
        failed: files.reduce(0) { $0 + $1.failed },
        roster: files.map { $0.stableName + "|" + ($0.disabled ? "1" : "0") }.sorted()
    )
}

private struct AuthTokenMetadata: Decodable, Sendable {
    let accountID: String?
    let planType: String?
    let subscriptionUntil: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "chatgpt_account_id"
        case planType = "plan_type"
        case subscriptionUntil = "chatgpt_subscription_active_until"
    }
}

private struct AuthStatusRequest: Encodable {
    let name: String
    let disabled: Bool
}

private struct NativeAPICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    init(authIndex: String, method: String, url: String, header: [String: String], data: String? = nil) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case authIndex
        case method
        case url
        case header
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authIndex, forKey: .authIndex)
        try container.encode(method, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encode(header, forKey: .header)
        if let data {
            try container.encode(data, forKey: .data)
        }
    }
}

private struct ParsedUsage {
    let planType: String?
    let windows: [String: QuotaWindow]
}

private func parseOpenAIUsage(_ data: Data, now: Date) throws -> ParsedUsage {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rateLimit = childMap(root, keys: ["rate_limit", "rateLimit"]) else {
        throw CPAError.invalidResponse
    }
    var windows: [String: QuotaWindow] = [:]
    for (key, alternate, name) in [
        ("primary_window", "primaryWindow", "primary"),
        ("secondary_window", "secondaryWindow", "secondary"),
    ] {
        guard let raw = childMap(rateLimit, keys: [key, alternate]),
              let used = number(raw["used_percent"] ?? raw["usedPercent"]) else { continue }
        let seconds = number(raw["limit_window_seconds"] ?? raw["limitWindowSeconds"]).map(Int64.init)
        let resetDate: Date?
        if let unix = number(raw["reset_at"] ?? raw["resetAt"]), unix > 0 {
            resetDate = Date(timeIntervalSince1970: unix)
        } else if let value = raw["reset_at"] as? String ?? raw["resetAt"] as? String {
            resetDate = QuotaDate.parse(value)
        } else if let after = number(raw["reset_after_seconds"] ?? raw["resetAfterSeconds"]) {
            resetDate = now.addingTimeInterval(after)
        } else {
            resetDate = nil
        }
        windows[name] = QuotaWindow(
            name: name,
            usedPercent: min(100, max(0, used)),
            resetAt: resetDate.map(QuotaDate.string),
            windowSeconds: seconds
        )
    }
    guard !windows.isEmpty else { throw CPAError.invalidResponse }
    let plan = (root["plan_type"] as? String ?? root["planType"] as? String)?.lowercased()
    return ParsedUsage(planType: plan, windows: windows)
}

private func parseAntigravityUsage(_ data: Data, pool: AccountPoolType, now: Date) throws -> ParsedUsage {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let groups = root["groups"] as? [[String: Any]],
          !groups.isEmpty else {
        throw CPAError.invalidResponse
    }

    // 根据选择的账号池提取对应的分组：
    // pool == .gemini 优先匹配包含 "gemini" 的模型分组
    // pool == .claude 优先匹配包含 "claude"、"3p"、"gpt" 的模型分组
    let targetGroup: [String: Any]?
    switch pool {
    case .gemini:
        targetGroup = groups.first { g in
            let name = (g["displayName"] as? String ?? g["display_name"] as? String ?? "").lowercased()
            return name.contains("gemini")
        } ?? groups.first
    case .claude:
        targetGroup = groups.first { g in
            let name = (g["displayName"] as? String ?? g["display_name"] as? String ?? "").lowercased()
            return name.contains("claude") || name.contains("3p") || name.contains("gpt")
        } ?? (groups.count > 1 ? groups[1] : groups.first)
    case .openai:
        targetGroup = groups.first
    }

    guard let chosen = targetGroup,
          let buckets = chosen["buckets"] as? [[String: Any]] else {
        throw CPAError.invalidResponse
    }

    var windows: [String: QuotaWindow] = [:]

    for bucket in buckets {
        let windowName = (bucket["window"] as? String ?? "").lowercased()
        let bucketId = (bucket["bucketId"] as? String ?? bucket["bucket_id"] as? String ?? "").lowercased()
        let displayName = (bucket["displayName"] as? String ?? bucket["display_name"] as? String ?? "").lowercased()
        guard let remainingFraction = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) else { continue }

        let used = max(0, min(100, (1.0 - remainingFraction) * 100))
        let resetDate: Date?
        if let rawReset = bucket["resetTime"] as? String ?? bucket["reset_time"] as? String {
            resetDate = QuotaDate.parse(rawReset)
        } else {
            resetDate = nil
        }

        let is5h = windowName == "5h" || bucketId.contains("5h") || displayName.contains("5") || displayName.contains("five")
        let isWeekly = windowName == "weekly" || bucketId.contains("weekly") || displayName.contains("week")

        if is5h && windows["primary"] == nil {
            windows["primary"] = QuotaWindow(
                name: "primary",
                usedPercent: used,
                resetAt: resetDate.map(QuotaDate.string),
                windowSeconds: 5 * 3600
            )
        } else if isWeekly && windows["secondary"] == nil {
            windows["secondary"] = QuotaWindow(
                name: "secondary",
                usedPercent: used,
                resetAt: resetDate.map(QuotaDate.string),
                windowSeconds: 7 * 24 * 3600
            )
        }
    }

    guard !windows.isEmpty else { throw CPAError.invalidResponse }
    return ParsedUsage(planType: "Antigravity", windows: windows)
}

private func parseClaudeUsage(_ data: Data, now: Date) throws -> ParsedUsage {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CPAError.invalidResponse
    }
    var windows: [String: QuotaWindow] = [:]

    if let fiveHour = root["five_hour"] as? [String: Any],
       let util = number(fiveHour["utilization"]) {
        let resetDate = (fiveHour["resets_at"] as? String).flatMap(QuotaDate.parse)
        windows["primary"] = QuotaWindow(
            name: "primary",
            usedPercent: max(0, min(100, util)),
            resetAt: resetDate.map(QuotaDate.string),
            windowSeconds: 5 * 3600
        )
    }

    if let sevenDay = root["seven_day"] as? [String: Any],
       let util = number(sevenDay["utilization"]) {
        let resetDate = (sevenDay["resets_at"] as? String).flatMap(QuotaDate.parse)
        windows["secondary"] = QuotaWindow(
            name: "secondary",
            usedPercent: max(0, min(100, util)),
            resetAt: resetDate.map(QuotaDate.string),
            windowSeconds: 7 * 24 * 3600
        )
    }

    guard !windows.isEmpty else { throw CPAError.invalidResponse }
    let plan = (root["plan"] as? String ?? root["plan_type"] as? String)?.capitalized ?? "Pro"
    return ParsedUsage(planType: plan, windows: windows)
}

private func threshold(for file: NativeAuthFile, settings: PluginSettings) -> Double {
    let overrides = Dictionary(uniqueKeysWithValues: settings.accountOverrides.map { ($0.key.lowercased(), $0.value) })
    for key in [file.stableName, file.id ?? "", file.authIndex, file.email ?? "", file.account ?? "", file.label ?? ""] {
        if let value = overrides[key.lowercased()] { return min(100, max(0, value)) }
    }
    return min(100, max(0, settings.remainingThresholdPercent))
}

private func triggeredRelease(for account: Account, now: Date) -> Date? {
    var release: Date?
    for window in [account.primary, account.secondary].compactMap({ $0 }) {
        guard window.remaining <= account.thresholdPercent,
              let reset = window.resetDate,
              reset > now else { continue }
        if release == nil || reset > release! { release = reset }
    }
    return release
}

private func copy(_ account: Account, disabled: Bool) -> Account {
    Account(
        id: account.id,
        name: account.name,
        label: account.label,
        email: account.email,
        authType: account.authType,
        channel: account.channel,
        planType: account.planType,
        subscriptionUntil: account.subscriptionUntil,
        credentialExpires: account.credentialExpires,
        hostDisabled: disabled,
        windows: account.windows,
        recentRequests: account.recentRequests,
        thresholdPercent: account.thresholdPercent,
        held: disabled,
        unknown: account.unknown,
        stale: account.stale,
        lastError: account.lastError
    )
}

private func makeSummary(accounts: [Account], settings: PluginSettings, now: Date, lastError: String?) -> CPASummary {
    let known = accounts.filter { !$0.unknown }.count
    let timestamp = QuotaDate.string(from: now)
    return CPASummary(
        generatedAt: timestamp,
        config: RuntimeConfig(
            remainingThresholdPercent: settings.remainingThresholdPercent,
            accountOverrides: settings.accountOverrides
        ),
        totalAccounts: accounts.count,
        knownAccounts: known,
        unknownAccounts: accounts.count - known,
        heldAccounts: accounts.filter(\.hostDisabled).count,
        primary: summarizeWindow(accounts: accounts, key: "primary", now: now),
        secondary: summarizeWindow(accounts: accounts, key: "secondary", now: now),
        recentRequests: aggregateRequests(accounts),
        accounts: accounts,
        lastScanAt: timestamp,
        lastScanError: lastError
    )
}

private func summarizeWindow(accounts: [Account], key: String, now: Date) -> WindowSummary {
    let windows = accounts.compactMap { $0.windows[key] }
    guard !windows.isEmpty else {
        return WindowSummary(knownAccounts: 0, averageRemainingPercent: 0, effectiveResetAt: nil, resetProgressPercent: nil)
    }
    let average = windows.reduce(0) { $0 + $1.remaining } / Double(windows.count)
    let samples = windows.compactMap { window -> (seconds: Double, progress: Double, weight: Double)? in
        guard let reset = window.resetDate,
              let duration = window.windowSeconds,
              duration > 0 else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let progress = min(100, max(0, seconds / Double(duration) * 100))
        return (seconds, progress, min(100, max(0, window.usedPercent)))
    }
    let weighted = samples.filter { $0.weight > 0 }
    let seconds: Double?
    let progress: Double?
    if !weighted.isEmpty {
        let weight = weighted.reduce(0) { $0 + $1.weight }
        seconds = weighted.reduce(0) { $0 + $1.seconds * $1.weight } / weight
        progress = weighted.reduce(0) { $0 + $1.progress * $1.weight } / weight
    } else if !samples.isEmpty {
        seconds = samples.reduce(0) { $0 + $1.seconds } / Double(samples.count)
        progress = samples.reduce(0) { $0 + $1.progress } / Double(samples.count)
    } else {
        seconds = nil
        progress = nil
    }
    return WindowSummary(
        knownAccounts: windows.count,
        averageRemainingPercent: average,
        effectiveResetAt: seconds.map { QuotaDate.string(from: now.addingTimeInterval($0)) },
        resetProgressPercent: progress
    )
}

private func aggregateRequests(_ accounts: [Account]) -> [RequestBucket] {
    var order: [String] = []
    var totals: [String: (Int64, Int64)] = [:]
    for account in accounts {
        for bucket in account.recentRequests where !bucket.time.isEmpty {
            if totals[bucket.time] == nil { order.append(bucket.time) }
            let previous = totals[bucket.time] ?? (0, 0)
            totals[bucket.time] = (previous.0 + bucket.success, previous.1 + bucket.failed)
        }
    }
    if order.count > 20 { order = Array(order.suffix(20)) }
    return order.map {
        let total = totals[$0] ?? (0, 0)
        return RequestBucket(time: $0, success: total.0, failed: total.1)
    }
}

private func childMap(_ object: [String: Any], keys: [String]) -> [String: Any]? {
    for key in keys {
        if let value = object[key] as? [String: Any] { return value }
    }
    return nil
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func responseMessage(_ data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for key in ["message", "error"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
    }
    return String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
