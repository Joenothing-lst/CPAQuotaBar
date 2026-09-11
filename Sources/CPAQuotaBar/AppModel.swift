import AppKit
#if canImport(CPAQuotaCore)
import CPAQuotaCore
#endif
import Foundation

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedPool: AccountPoolType
    @Published var summary: CPASummary?
    @Published var address: String
    @Published var managementKey: String
    @Published var monitorSettings: PluginSettings
    @Published var overridesText: String
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var connectionTestState: ConnectionTestState = .idle
    @Published var isShowingCachedFallback = false

    private var pollingTask: Task<Void, Never>?
    private var currentRefreshTask: Task<Void, Never>?
    private var poolSwitchDebounceTask: Task<Void, Never>?
    private var panelVisible = false
    private var authenticationPaused = false
    private var managedHolds: [String: Date]
    private var lastActivitySnapshot: CPAActivitySnapshot?
    private var lastActivityAt: Date?
    private var lastQuotaRefreshAt: [AccountPoolType: Date] = [:]
    private let defaults = UserDefaults.standard

    private static let selectedPoolKey = "cpaSelectedPool"
    private static let addressKey = "cpaAddress"
    private static let managementKeyKey = "managementKey"
    private static let settingsKey = "nativeMonitorSettings"
    private static let holdsKey = "nativeManagedHolds"
    private static let summaryCacheKey = "lastKnownGoodSummary"
    static let defaultAddress = "http://127.0.0.1:8317"

    static func normalizeAddress(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = defaultAddress }
        while value.hasSuffix("/") { value.removeLast() }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        return value
    }

    init() {
        let defaults = UserDefaults.standard
        let savedSettings = Self.loadSettings(from: defaults)
        let savedAddress = defaults.string(forKey: Self.addressKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAddress = (savedAddress?.isEmpty ?? true) ? Self.defaultAddress : savedAddress!
        let savedPoolRaw = defaults.string(forKey: Self.selectedPoolKey) ?? AccountPoolType.openai.rawValue
        let resolvedPool = AccountPoolType(rawValue: savedPoolRaw) ?? .openai

        selectedPool = resolvedPool
        address = resolvedAddress
        managementKey = defaults.string(forKey: Self.managementKeyKey) ?? ""
        monitorSettings = savedSettings
        managedHolds = Self.loadHolds(from: defaults)
        overridesText = Self.formatOverrides(savedSettings.accountOverrides)

        let normalized = Self.normalizeAddress(resolvedAddress)
        if let cached = Self.loadCachedSummary(from: defaults, address: normalized, pool: resolvedPool) {
            summary = cached
            isShowingCachedFallback = true
        }

        Task { [weak self] in self?.start() }
    }

    deinit {
        pollingTask?.cancel()
        currentRefreshTask?.cancel()
        poolSwitchDebounceTask?.cancel()
    }

    var connected: Bool { summary != nil && (!isShowingCachedFallback || errorMessage == nil) }

    var menuPrimaryWindow: WindowSummary? {
        summary?.primary
    }

    var menuSecondaryWindow: WindowSummary? {
        summary?.secondary
    }

    var sortedAccounts: [Account] {
        summary?.accounts.sorted {
            let leftRank = Self.statusRank($0)
            let rightRank = Self.statusRank($1)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftQuota = min($0.primary?.remaining ?? 101, $0.secondary?.remaining ?? 101)
            let rightQuota = min($1.primary?.remaining ?? 101, $1.secondary?.remaining ?? 101)
            if leftQuota != rightQuota { return leftQuota < rightQuota }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        } ?? []
    }

    private static func statusRank(_ account: Account) -> Int {
        if account.hostDisabled { return 1 }
        if account.unknown || account.stale || !(account.lastError?.isEmpty ?? true) { return 2 }
        return 0
    }

    func start() {
        guard pollingTask == nil, !authenticationPaused else { return }
        pollingTask = Task { [weak self] in
            // 首次启动且当前账号池尚无任何数据时，同步拉取一次当前选中池
            if let self, self.summary == nil, !self.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await self.loadStatus()
            }
            while !Task.isCancelled {
                guard let self else { return }
                if self.panelVisible {
                    let now = Date()
                    let activeInterval = Self.durationSeconds(self.monitorSettings.refreshInterval, fallback: 60)
                    let lastRefresh = self.lastQuotaRefreshAt[self.selectedPool]
                    if lastRefresh.map({ now.timeIntervalSince($0) >= Double(activeInterval) }) ?? true {
                        await self.loadStatus()
                    }
                } else {
                    await self.backgroundTick()
                }
                guard !self.authenticationPaused else { return }
                let seconds = self.panelVisible
                    ? Self.durationSeconds(self.monitorSettings.refreshInterval, fallback: 60)
                    : 60
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        if visible {
            let now = Date()
            let activeInterval = Self.durationSeconds(monitorSettings.refreshInterval, fallback: 60)
            let lastRefresh = lastQuotaRefreshAt[selectedPool]
            if lastRefresh.map({ now.timeIntervalSince($0) >= Double(activeInterval) }) ?? true {
                currentRefreshTask?.cancel()
                currentRefreshTask = Task { [weak self] in await self?.loadStatus() }
            }
        }
    }

    func selectPool(_ pool: AccountPoolType) {
        guard selectedPool != pool else { return }
        // 1. 取消上一个账号池正在等待的防抖任务和正在飞行的网络任务
        poolSwitchDebounceTask?.cancel()
        currentRefreshTask?.cancel()
        currentRefreshTask = nil

        selectedPool = pool
        defaults.set(pool.rawValue, forKey: Self.selectedPoolKey)
        errorMessage = nil

        // 2. 立即展示目标池的本地缓存，秒级切换无等待感
        if let cached = Self.loadCachedSummary(from: defaults, address: normalizedAddress, pool: pool) {
            summary = cached
            isShowingCachedFallback = false
        } else {
            summary = nil
            isShowingCachedFallback = false
        }
        lastActivitySnapshot = nil

        // 3. 2s 防抖延迟：短时间频繁切换时不发网络请求；用户停留在当前池超过 2s 且该池缓存过期时才拉取
        poolSwitchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }

            let lastRefresh = self.lastQuotaRefreshAt[pool]
            let activeInterval = Self.durationSeconds(self.monitorSettings.refreshInterval, fallback: 60)
            let isStale = lastRefresh.map { Date().timeIntervalSince($0) >= Double(activeInterval) } ?? true
            if isStale {
                self.currentRefreshTask = Task { [weak self] in
                    await self?.loadStatus(for: pool)
                }
            }
        }
    }

    func loadStatus(for pool: AccountPoolType? = nil) async {
        let targetPool = pool ?? selectedPool
        guard !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if targetPool == selectedPool {
                summary = nil
                errorMessage = "请在设置中填写 Management Key"
            }
            return
        }
        do {
            let result = try await client.fetchStatus(
                pool: targetPool,
                settings: monitorSettings,
                managedHolds: managedHolds,
                applyPolicy: true
            )
            guard !Task.isCancelled else { return }
            accept(result, for: targetPool, detectsActivity: true)
        } catch {
            guard !Task.isCancelled else { return }
            if targetPool == selectedPool {
                handleConnectionError(error)
            }
        }
    }

    func testConnection() async {
        guard connectionTestState != .testing else { return }
        connectionTestState = .testing
        let targetAddress = Self.normalizeAddress(address)
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            address = targetAddress
        }
        let key = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            connectionTestState = .failure("请在设置中填写 Management Key")
            return
        }
        let testClient = CPAClient(
            address: targetAddress,
            managementKey: key
        )
        do {
            let count = try await testClient.testConnectivity(pool: selectedPool)
            connectionTestState = .success("连接成功 · 已连通 CPA，检测到 \(count) 个 \(selectedPool.displayName) 账号")
        } catch {
            let message = error.localizedDescription
            connectionTestState = .failure(message)
        }
    }

    func refreshNow() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        poolSwitchDebounceTask?.cancel()
        currentRefreshTask?.cancel()
        await loadStatus(for: selectedPool)
    }

    func saveSettings() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            monitorSettings.accountOverrides = try Self.parseOverrides(overridesText)
            address = Self.normalizeAddress(address)
            managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(address, forKey: Self.addressKey)
            defaults.set(managementKey, forKey: Self.managementKeyKey)
            defaults.set(try JSONEncoder().encode(monitorSettings), forKey: Self.settingsKey)
            authenticationPaused = false
            let targetPool = selectedPool
            let result = try await client.fetchStatus(
                pool: targetPool,
                settings: monitorSettings,
                managedHolds: managedHolds,
                applyPolicy: true
            )
            accept(result, for: targetPool, detectsActivity: true)
            restartPolling()
            return true
        } catch {
            handleConnectionError(error)
            return false
        }
    }

    func openManagementCenter() {
        let target = Self.normalizeAddress(address)
        guard let url = URL(string: target + "/management.html#/quota") else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() { NSApplication.shared.terminate(nil) }

    private var client: CPAClient { CPAClient(address: address, managementKey: managementKey) }

    private func backgroundTick() async {
        let now = Date()
        if managedHolds.values.contains(where: { $0 <= now }) {
            await loadStatus()
            return
        }

        let activeFor = Self.durationSeconds(monitorSettings.idleAfter, fallback: 300)
        let isActive = lastActivityAt.map {
            now.timeIntervalSince($0) < Double(activeFor)
        } ?? false
        let configured = isActive
            ? monitorSettings.refreshInterval
            : monitorSettings.idleRefreshInterval
        let fallback: UInt64 = isActive ? 60 : 3_600
        let fullRefreshInterval = Self.durationSeconds(configured, fallback: fallback)
        let lastRefresh = lastQuotaRefreshAt[selectedPool]
        if lastRefresh.map({ now.timeIntervalSince($0) >= Double(fullRefreshInterval) }) ?? true {
            await loadStatus()
            return
        }

        do {
            let next = try await client.fetchActivitySnapshot(pool: selectedPool)
            let changed = lastActivitySnapshot.map { $0 != next } ?? false
            lastActivitySnapshot = next
            if changed {
                lastActivityAt = now
                await loadStatus()
            }
        } catch {
            handleConnectionError(error)
        }
    }

    private func accept(_ result: NativeFetchResult, for pool: AccountPoolType, detectsActivity: Bool) {
        if detectsActivity,
           let previous = lastActivitySnapshot,
           previous != result.activity {
            lastActivityAt = Date()
        }
        lastActivitySnapshot = result.activity
        lastQuotaRefreshAt[pool] = Date()
        managedHolds = result.managedHolds
        persistHolds()

        let incoming = result.summary
        let allFailed = incoming.totalAccounts > 0 && incoming.knownAccounts == 0

        if allFailed {
            // 当所有账号的额度请求同时短暂失败（上游 OpenAI 抖动或网络波动）：
            // 绝不将这次“账号存在但额度全未知”的结果覆盖旧数据！
            // 继续保留上一次的有效缓存结果，并在界面上亮起黄灯！
            let existing = (pool == selectedPool ? self.summary : nil) ?? Self.loadCachedSummary(from: defaults, address: normalizedAddress, pool: pool)
            if let existing {
                let fallbackSummary = CPASummary(
                    generatedAt: existing.generatedAt,
                    config: incoming.config,
                    totalAccounts: incoming.totalAccounts,
                    knownAccounts: existing.knownAccounts,
                    unknownAccounts: existing.unknownAccounts,
                    heldAccounts: incoming.heldAccounts,
                    primary: existing.primary,
                    secondary: existing.secondary,
                    recentRequests: incoming.recentRequests.isEmpty ? existing.recentRequests : incoming.recentRequests,
                    accounts: existing.accounts,
                    refreshing: false,
                    lastScanAt: existing.lastScanAt,
                    lastScanError: incoming.lastScanError ?? quotaFallbackMessage
                )
                if pool == selectedPool {
                    self.summary = fallbackSummary
                    self.isShowingCachedFallback = true
                    self.errorMessage = quotaFallbackMessage
                    self.authenticationPaused = false
                }
                return
            }
        }

        // 刷新成功（至少有账号拿到额度），或账号池本来为空
        var finalAccounts = incoming.accounts
        // 如果有少量账号偶发超时，继承上一轮有效 windows 并标记 stale，防止单账号跳变
        let prevSource = (pool == selectedPool ? self.summary : nil) ?? Self.loadCachedSummary(from: defaults, address: normalizedAddress, pool: pool)
        if let prevAccounts = prevSource?.accounts, !prevAccounts.isEmpty {
            let prevMap = Dictionary(uniqueKeysWithValues: prevAccounts.map { ($0.id, $0) })
            for i in finalAccounts.indices where finalAccounts[i].unknown {
                if let prev = prevMap[finalAccounts[i].id], !prev.windows.isEmpty {
                    finalAccounts[i] = Account(
                        id: finalAccounts[i].id,
                        name: finalAccounts[i].name,
                        label: finalAccounts[i].label,
                        email: finalAccounts[i].email,
                        authType: finalAccounts[i].authType,
                        channel: finalAccounts[i].channel ?? prev.channel,
                        planType: finalAccounts[i].planType ?? prev.planType,
                        subscriptionUntil: finalAccounts[i].subscriptionUntil ?? prev.subscriptionUntil,
                        credentialExpires: finalAccounts[i].credentialExpires ?? prev.credentialExpires,
                        hostDisabled: finalAccounts[i].hostDisabled,
                        windows: prev.windows,
                        recentRequests: finalAccounts[i].recentRequests,
                        thresholdPercent: finalAccounts[i].thresholdPercent,
                        held: finalAccounts[i].held,
                        unknown: false,
                        stale: true,
                        lastError: finalAccounts[i].lastError
                    )
                }
            }
        }

        let finalSummary = CPASummary(
            generatedAt: incoming.generatedAt,
            config: incoming.config,
            totalAccounts: incoming.totalAccounts,
            knownAccounts: finalAccounts.filter { !$0.unknown }.count,
            unknownAccounts: finalAccounts.filter { $0.unknown }.count,
            heldAccounts: incoming.heldAccounts,
            primary: incoming.primary.remaining != nil ? incoming.primary : (prevSource?.primary ?? incoming.primary),
            secondary: incoming.secondary.remaining != nil ? incoming.secondary : (prevSource?.secondary ?? incoming.secondary),
            recentRequests: incoming.recentRequests,
            accounts: finalAccounts,
            refreshing: incoming.refreshing,
            lastScanAt: incoming.lastScanAt,
            lastScanError: incoming.lastScanError
        )

        // 关键防护 1：永远将数据保存到其真实所属的 pool 缓存中，绝不借用当前动态的 selectedPool
        Self.saveCachedSummary(finalSummary, for: normalizedAddress, pool: pool, to: defaults)

        // 关键防护 2：如果在此次网络请求执行期间用户已切到了其他账号池，绝不覆盖当前界面的 summary
        guard pool == selectedPool else {
            return
        }

        self.summary = finalSummary
        self.isShowingCachedFallback = false

        let errors = [finalSummary.lastScanError].compactMap { $0 }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "；")
        authenticationPaused = false
    }

    private var quotaFallbackMessage: String {
        "本次额度刷新失败，正在显示上次有效值"
    }

    private var normalizedAddress: String {
        Self.normalizeAddress(address)
    }

    private func restartPolling() {
        poolSwitchDebounceTask?.cancel()
        poolSwitchDebounceTask = nil
        currentRefreshTask?.cancel()
        currentRefreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        start()
    }

    private func handleConnectionError(_ error: Error) {
        errorMessage = error.localizedDescription
        if summary != nil {
            isShowingCachedFallback = true
        }
        if isAuthenticationError(error) {
            authenticationPaused = true
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        guard case let CPAError.http(code, _) = error else { return false }
        return code == 401 || code == 403
    }

    private func persistHolds() {
        let values = managedHolds.mapValues(\.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.holdsKey) }
    }

    private static func loadCachedSummary(from defaults: UserDefaults, address: String, pool: AccountPoolType) -> CPASummary? {
        let key = summaryCacheKey + "_" + pool.rawValue
        guard let data = defaults.data(forKey: key),
              let envelope = try? JSONDecoder().decode(CachedSummaryEnvelope.self, from: data),
              envelope.address == address else { return nil }
        return envelope.summary
    }

    private static func saveCachedSummary(_ summary: CPASummary, for address: String, pool: AccountPoolType, to defaults: UserDefaults) {
        let key = summaryCacheKey + "_" + pool.rawValue
        let envelope = CachedSummaryEnvelope(address: address, summary: summary)
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: key)
        }
    }

    private struct CachedSummaryEnvelope: Codable {
        let address: String
        let summary: CPASummary
    }

    private static func loadSettings(from defaults: UserDefaults) -> PluginSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(PluginSettings.self, from: data) else {
            return PluginSettings()
        }
        return value
    }

    private static func loadHolds(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: holdsKey),
              let values = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return values.mapValues(Date.init(timeIntervalSince1970:))
    }

    private static func durationSeconds(_ raw: String, fallback: UInt64) -> UInt64 {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let unit = value.last,
              let number = Double(value.dropLast()),
              number.isFinite,
              number > 0 else { return fallback }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: return fallback
        }
        return UInt64(max(60, number * multiplier))
    }

    private static func formatOverrides(_ values: [String: Double]) -> String {
        values.keys.sorted().map { "\($0)=\(Int(values[$0] ?? 0))" }.joined(separator: "\n")
    }

    private static func parseOverrides(_ value: String) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for (index, rawLine) in value.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == ":" })
            guard parts.count == 2,
                  let percent = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  (0...100).contains(percent) else {
                throw NSError(
                    domain: "CPAQuotaBar.Settings",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "账号覆盖第 \(index + 1) 行格式无效，应为 account=percent"]
                )
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            result[key] = percent
        }
        return result
    }
}
