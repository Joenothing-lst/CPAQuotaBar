#if canImport(CPAQuotaCore)
import CPAQuotaCore
#endif
import AppKit
import SwiftUI

private enum AppPalette {
    static let aqua = Color(red: 0.02, green: 0.76, blue: 0.78)
    static let blue = Color(red: 0.14, green: 0.52, blue: 0.96)
    static let success = Color(red: 0.05, green: 0.68, blue: 0.28)
    static let warning = Color(red: 0.90, green: 0.66, blue: 0.00)
    static let danger = Color(red: 0.88, green: 0.12, blue: 0.14)
    static let track = Color.primary.opacity(0.10)
}

struct StatusBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let threshold = model.summary?.config.remainingThresholdPercent ?? 10
        let primary = model.menuPrimaryWindow
        let secondary = model.menuSecondaryWindow
        HStack(spacing: 6) {
            ProviderBrandIcon(pool: model.selectedPool, isSelected: true)
                .frame(width: 15.5, height: 15.5)
            if primary?.remaining != nil || secondary?.remaining == nil {
                MenuMiniRing(
                    value: primary?.remaining,
                    threshold: threshold,
                    resetProgress: primary?.resetProgressPercent
                )
            }
            MenuMiniRing(
                value: secondary?.remaining,
                threshold: threshold,
                resetProgress: secondary?.resetProgressPercent
            )
        }
        .accessibilityLabel(primary?.remaining == nil && secondary?.remaining != nil
            ? "\(model.selectedPool.displayName) 额度，1周 \(formatted(secondary?.remaining))"
            : "\(model.selectedPool.displayName) 额度，5小时 \(formatted(primary?.remaining))，1周 \(formatted(secondary?.remaining))")
    }

    private func formatted(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "未知" }
}

private struct MenuMiniRing: View {
    let value: Double?
    let threshold: Double
    let resetProgress: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.6)
            if let value {
                Circle()
                    .trim(from: 0, to: value / 100)
                    .stroke(ringColor(value), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map { String(Int($0.rounded())) } ?? "–")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .offset(x: 0.5, y: 0.7)
        }
        .frame(width: 22, height: 22)
    }

    private func ringColor(_ value: Double) -> Color {
        if value <= threshold { return AppPalette.danger }
        if let resetProgress, value + 5 < resetProgress { return AppPalette.warning }
        return AppPalette.success
    }
}

@propertyWrapper
private struct UIState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        self.storage = SwiftUI.State(wrappedValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> {
        storage.projectedValue
    }
}

private let accountRowHeight: CGFloat = 78

private func accountViewportHeight(count: Int) -> CGFloat {
    if count == 0 { return 60 }
    let visible = min(count, 4)
    let dividers = CGFloat(max(0, visible - 1))
    return CGFloat(visible) * accountRowHeight + dividers
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @UIState private var showingSettings = false
    @UIState private var accountsExpanded = false
    @UIState private var accountsMasked = false
    let preferredHeight: (CGFloat) -> Void

    private var panelHeight: CGFloat {
        if showingSettings { return 700 }
        if model.summary == nil {
            return model.isPoolLoading && accountsExpanded ? 430 : 340
        }
        return dashboardHeight(accountsExpanded: accountsExpanded)
    }

    private func dashboardHeight(accountsExpanded: Bool) -> CGFloat {
        let navBarHeight: CGFloat = 46
        if accountsExpanded {
            let count = model.sortedAccounts.count
            let viewportHeight = accountViewportHeight(count: count)
            return min(720, 336 + navBarHeight + viewportHeight)
        }
        return 335 + navBarHeight
    }

    private func toggleAccounts() {
        let willExpand = !accountsExpanded
        guard !showingSettings else {
            accountsExpanded = willExpand
            return
        }
        // 内外容器在同一微秒同步延伸/收缩，轻微加速减速物理效果，无任何弹跳
        let targetHeight = dashboardHeight(accountsExpanded: willExpand)
        preferredHeight(targetHeight)
        withAnimation(.easeInOut(duration: 0.26)) {
            accountsExpanded = willExpand
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [AppPalette.blue.opacity(0.10), AppPalette.aqua.opacity(0.04), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if showingSettings {
                        SettingsView(model: model) { showingSettings = false }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        DashboardView(
                            model: model,
                            accountsExpanded: accountsExpanded,
                            accountsMasked: accountsMasked,
                            toggleAccounts: toggleAccounts,
                            toggleAccountsMask: { accountsMasked.toggle() }
                        ) {
                            showingSettings = true
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(width: 430)
        .frame(maxHeight: .infinity, alignment: .top)
        .dynamicTypeSize(.xxLarge)
        .animation(.easeInOut(duration: 0.26), value: showingSettings)
        .onAppear { preferredHeight(panelHeight) }
        .onChange(of: showingSettings) { _, _ in preferredHeight(panelHeight) }
        .onChange(of: model.sortedAccounts.count) { _, _ in preferredHeight(panelHeight) }
        .onChange(of: model.isPoolLoading) { _, _ in preferredHeight(panelHeight) }
        .onChange(of: model.selectedPool) { _, _ in
            // 没有目标池缓存时，网络返回后直接展示账号池，避免用户还要再次点击展开。
            if model.summary == nil {
                accountsExpanded = true
            }
            preferredHeight(panelHeight)
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: AppModel
    let accountsExpanded: Bool
    let accountsMasked: Bool
    let toggleAccounts: () -> Void
    let toggleAccountsMask: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            header
            accountPoolNavBar

            if let summary = model.summary {
                summaryCard(summary)
                counters(summary)
                accountDisclosure(summary)
            } else if model.isPoolLoading {
                loadingPool
            } else {
                unavailable
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var accountPoolNavBar: some View {
        HStack(spacing: 6) {
            ForEach(AccountPoolType.allCases) { pool in
                let isSelected = model.selectedPool == pool
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        model.selectPool(pool)
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProviderBrandIcon(pool: pool, isSelected: isSelected)
                            .frame(width: 15, height: 15)
                        Text(pool.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
                                )
                                .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .help(poolHelpText(for: pool))
            }
        }
        .padding(4)
        .quotaGlass(cornerRadius: 13, tint: Color.primary.opacity(0.035))
    }

    private func poolHelpText(for pool: AccountPoolType) -> String {
        switch pool {
        case .openai: return "切换至 OpenAI (Codex) 账号池"
        case .gemini: return "切换至 Gemini (Antigravity) 账号池"
        case .claude: return "切换至 Claude (Antigravity/Claude) 账号池"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(headerGradient(for: model.selectedPool).opacity(0.18))
                    .overlay(
                        Circle().stroke(headerGradient(for: model.selectedPool).opacity(0.40), lineWidth: 1)
                    )
                ProviderBrandIcon(pool: model.selectedPool, isSelected: true, mono: false)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("CPA Quota")
                        .font(.headline.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(model.selectedPool.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 5, height: 5)
                    Text(lastUpdatedText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.openManagementCenter() } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)
            .help("打开管理中心")

            Button { Task { await model.refreshNow() } } label: {
                ConcentricRefreshIcon(isLoading: model.isLoading)
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)
            .disabled(model.isLoading)
            .help("立即刷新")

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)
            .help("设置")

            Button { model.quit() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)
            .help("退出 CPA Quota Bar")

        }
    }

    private func headerGradient(for pool: AccountPoolType) -> LinearGradient {
        switch pool {
        case .openai:
            return LinearGradient(
                colors: [Color(red: 0.06, green: 0.76, blue: 0.58), Color(red: 0.02, green: 0.54, blue: 0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .gemini:
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.52, blue: 0.98), Color(red: 0.68, green: 0.38, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .claude:
            return LinearGradient(
                colors: [Color(red: 0.92, green: 0.48, blue: 0.32), Color(red: 0.82, green: 0.32, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var statusDotColor: Color {
        if model.isShowingCachedFallback {
            return AppPalette.warning
        }
        return model.connected ? AppPalette.success : AppPalette.danger
    }

    private var lastUpdatedText: String {
        if model.isShowingCachedFallback {
            if let date = model.summary?.lastScanAt.flatMap(QuotaDate.parse) {
                return "更新于 " + date.formatted(date: .omitted, time: .shortened) + " (缓存)"
            }
            return "显示上次有效值"
        }
        guard let date = model.summary?.lastScanAt.flatMap(QuotaDate.parse) else {
            return model.connected ? "尚未更新" : "等待连接"
        }
        return "更新于 " + date.formatted(date: .omitted, time: .shortened)
    }

    private func summaryCard(_ summary: CPASummary) -> some View {
        VStack(spacing: 13) {
            HStack(spacing: 28) {
                if summary.primary.remaining != nil || summary.secondary.remaining == nil {
                    QuotaRingView(
                        label: "5h",
                        value: summary.primary.remaining,
                        threshold: summary.config.remainingThresholdPercent,
                        resetProgress: summary.primary.resetProgressPercent,
                        resetDate: summary.primary.resetDate,
                        diameter: 126
                    )
                }
                QuotaRingView(
                    label: "1w",
                    value: summary.secondary.remaining,
                    threshold: summary.config.remainingThresholdPercent,
                    resetProgress: summary.secondary.resetProgressPercent,
                    resetDate: summary.secondary.resetDate,
                    diameter: 126
                )
            }
            StatusBlocksView(buckets: summary.recentRequests, showsTotal: true)
        }
        .padding(15)
        .quotaGlass(cornerRadius: 24, tint: AppPalette.blue.opacity(0.06))
    }

    private func counters(_ summary: CPASummary) -> some View {
        HStack(spacing: 8) {
            CounterPill(value: summary.totalAccounts, label: "账号")
            CounterPill(
                value: max(0, summary.totalAccounts - summary.heldAccounts),
                label: "已启用"
            )
            CounterPill(value: summary.heldAccounts, label: "已禁用", warning: summary.heldAccounts > 0)
        }
    }

    private func accountDisclosure(_ summary: CPASummary) -> some View {
        let accounts = model.sortedAccounts
        let viewportHeight = accountViewportHeight(count: accounts.count)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: toggleAccounts) {
                    HStack {
                        Label("\(model.selectedPool.displayName) 账号池", systemImage: "person.2.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("\(summary.totalAccounts)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(accountsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button(action: toggleAccountsMask) {
                    Image(systemName: accountsMasked ? "eye.slash" : "eye")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(accountsMasked ? "显示账号" : "脱敏账号")
                .accessibilityLabel(accountsMasked ? "显示账号" : "脱敏账号")
            }
            .padding(13)

            VStack(spacing: 0) {
                Divider().opacity(0.45)

                if accounts.isEmpty {
                    Text("暂无 \(model.selectedPool.displayName) 账号")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: viewportHeight)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(accounts) { account in
                                AccountRow(account: account, isMasked: accountsMasked)
                                if account.id != accounts.last?.id {
                                    Divider().opacity(0.30)
                                }
                            }
                        }
                    }
                    .frame(height: viewportHeight)
                }
            }
            .frame(height: accountsExpanded ? viewportHeight + 1 : 0, alignment: .top)
            .clipped()
            .opacity(accountsExpanded ? 1 : 0)
            .allowsHitTesting(accountsExpanded)
            .accessibilityHidden(!accountsExpanded)
        }
        .quotaGlass(cornerRadius: 18, tint: AppPalette.aqua.opacity(0.035))
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: model.managementKey.isEmpty ? "bolt.horizontal.circle" : "arrow.clockwise.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(model.managementKey.isEmpty ? AppPalette.warning : Color.accentColor)
            Text(model.errorMessage ?? (model.managementKey.isEmpty ? "请在设置中填写 Management Key" : "当前 \(model.selectedPool.displayName) 账号池暂无本地数据"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if model.managementKey.isEmpty {
                Button("打开设置", action: openSettings)
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isLoading { ProgressView().controlSize(.small) }
                        Text(model.isLoading ? "正在刷新…" : "立即刷新 \(model.selectedPool.displayName) 额度")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding()
        .quotaGlass(cornerRadius: 24, tint: (model.managementKey.isEmpty ? AppPalette.warning : Color.accentColor).opacity(0.04))
    }

    private var loadingPool: some View {
        VStack(spacing: 0) {
            Button(action: toggleAccounts) {
                HStack {
                    Label("\(model.selectedPool.displayName) 账号池", systemImage: "person.2.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ProgressView().controlSize(.small)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(accountsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(13)
            if accountsExpanded {
                Divider().opacity(0.45)
                Text("正在加载账号列表…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .quotaGlass(cornerRadius: 18, tint: Color.accentColor.opacity(0.04))
    }
}

private struct CounterPill: View {
    let value: Int
    let label: String
    var warning = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)").fontWeight(.bold).foregroundStyle(warning ? AppPalette.warning : .primary)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .quotaGlass(cornerRadius: 99, tint: warning ? AppPalette.warning.opacity(0.06) : .clear)
    }
}

struct QuotaRingView: View {
    let label: String
    let value: Double?
    let threshold: Double
    let resetProgress: Double?
    let resetDate: Date?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            ringCanvas
            VStack(spacing: diameter > 90 ? 4 : -1) {
                Text(label)
                    .font(.system(size: diameter > 90 ? 14 : 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.system(size: diameter > 90 ? 36 : 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(QuotaMath.countdown(to: resetDate))
                    .font(.system(size: diameter > 90 ? 12 : 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) 剩余 \(value.map { String(Int($0.rounded())) } ?? "未知")，\(QuotaMath.countdown(to: resetDate)) 后重置")
    }

    private var lineWidth: CGFloat { diameter > 90 ? 10 : 6 }
    private var canvasBleed: CGFloat { diameter > 90 ? 6 : 4 }

    private var ringCanvas: some View {
        Canvas { context, canvasSize in
            // The radial reset tick extends beyond the ring and carries a shadow.
            // Give it a larger backing canvas while keeping the logical ring size
            // unchanged, so neither end is clipped by the Canvas bitmap boundary.
            let size = max(0, min(canvasSize.width, canvasSize.height) - canvasBleed * 2)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = size * 0.44
            let ringRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            context.stroke(
                Path(ellipseIn: ringRect),
                with: .color(AppPalette.track),
                style: StrokeStyle(lineWidth: lineWidth)
            )

            if let value {
                var progressPath = Path()
                progressPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + value / 100 * 360),
                    clockwise: false
                )
                context.stroke(
                    progressPath,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }

            if let progress = resetProgress {
                let angle = progress / 100 * .pi * 2 - .pi / 2
                let halfLength = size * 0.045
                var tickPath = Path()
                tickPath.move(to: CGPoint(
                    x: center.x + (radius - halfLength) * cos(angle),
                    y: center.y + (radius - halfLength) * sin(angle)
                ))
                tickPath.addLine(to: CGPoint(
                    x: center.x + (radius + halfLength) * cos(angle),
                    y: center.y + (radius + halfLength) * sin(angle)
                ))
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.68), radius: size * 0.012))
                    layer.stroke(
                        tickPath,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: size * 0.027, lineCap: .round)
                    )
                }
            }
        }
        .frame(width: diameter + canvasBleed * 2, height: diameter + canvasBleed * 2)
        .allowsHitTesting(false)
    }

    private var color: Color {
        guard let value else { return .secondary }
        if value <= threshold { return AppPalette.danger }
        if let resetProgress, value + 5 < resetProgress { return AppPalette.warning }
        return AppPalette.success
    }
}

private struct StatusBlocksView: View {
    let buckets: [RequestBucket]
    var showsTotal = false

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    RequestStatusBlock(
                        bucket: bucket,
                        color: blockColor(bucket),
                        index: index,
                        total: buckets.count
                    )
                }
            }
            .frame(height: 8)

            if showsTotal {
                Text(totalRate)
                    .fontWeight(.bold)
                    .monospacedDigit()
                .font(.caption2)
                .fixedSize()
            }
        }
    }

    private var totalRate: String {
        QuotaMath.totalSuccessRate(buckets).map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func blockColor(_ bucket: RequestBucket) -> Color {
        guard let rate = bucket.successRate else { return Color.primary.opacity(0.08) }
        return Color(hue: max(0, min(0.35, rate / 100 * 0.35)), saturation: 0.76, brightness: 0.78)
    }
}

private struct RequestStatusBlock: View {
    let bucket: RequestBucket
    let color: Color
    let index: Int
    let total: Int

    @UIState private var isHovering = false

    private var tooltipXOffset: CGFloat {
        guard total > 1 else { return 0 }
        if index == 0 { return 54 }
        if index == 1 { return 36 }
        if index == 2 { return 18 }
        if index == total - 1 { return -54 }
        if index == total - 2 { return -36 }
        if index == total - 3 { return -18 }
        return 0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .overlay(alignment: .top) {
                if isHovering {
                    HStack(spacing: 8) {
                        Text(bucket.time)
                            .foregroundStyle(.primary)

                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppPalette.success)
                            Text("\(bucket.success)")
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .foregroundStyle(AppPalette.danger)
                            Text("\(bucket.failed)")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.14), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .offset(x: tooltipXOffset, y: -38)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .allowsHitTesting(false)
                    .zIndex(20)
                }
            }
            .zIndex(isHovering ? 20 : 0)
    }
}

private struct AccountRow: View {
    let account: Account
    let isMasked: Bool

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.40), radius: 3)

            VStack(alignment: .leading, spacing: 7) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    if let channel = account.channel { ChannelTag(text: channel) }
                    if let plan = account.planType { PlanTag(plan: plan) }
                    if let validity = account.validityDate {
                        MetaTag(text: "至 " + validity.formatted(date: .numeric, time: .omitted))
                    }
                }
                StatusBlocksView(buckets: account.recentRequests)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keep the floating request detail above the quota rings. Without a
            // sibling z-index, the rings are composited after this VStack and
            // appear to bleed through the tooltip.
            .zIndex(1)

            if account.primary != nil || account.secondary == nil {
                QuotaRingView(
                    label: "5h",
                    value: account.primary?.remaining,
                    threshold: account.thresholdPercent,
                    resetProgress: account.primary?.resetProgress(),
                    resetDate: account.primary?.resetDate,
                    diameter: 58
                )
            }
            QuotaRingView(
                label: "1w",
                value: account.secondary?.remaining,
                threshold: account.thresholdPercent,
                resetProgress: account.secondary?.resetProgress(),
                resetDate: account.secondary?.resetDate,
                diameter: 58
            )
        }
        .padding(.horizontal, 12)
        .frame(height: accountRowHeight)
    }

    private var displayName: String {
        guard isMasked else { return account.displayName }
        let value = account.displayName
        if let at = value.firstIndex(of: "@"), at != value.startIndex {
            let local = value[..<at]
            let visible = local.prefix(1)
            return "\(visible)***\(value[at...])"
        }
        if value.count <= 2 { return value.prefix(1) + "***" }
        return "\(value.prefix(1))***\(value.suffix(1))"
    }

    private var statusColor: Color {
        if account.hostDisabled { return AppPalette.warning }
        if account.unknown || account.stale || !(account.lastError?.isEmpty ?? true) {
            return AppPalette.danger
        }
        return AppPalette.success
    }
}

private struct ChannelTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppPalette.aqua)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppPalette.aqua.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.aqua.opacity(0.35), lineWidth: 0.7))
    }
}

private struct PlanTag: View {
    let plan: String
    var body: some View {
        Text(QuotaMath.planDisplayName(plan))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.30), lineWidth: 0.7))
    }
    private var color: Color {
        if QuotaMath.isProLitePlan(plan) { return .orange }
        switch plan.lowercased() {
        case "plus": return .purple
        case "team": return AppPalette.blue
        case "pro": return .orange
        case "antigravity": return AppPalette.aqua
        case "ultra": return Color(red: 0.65, green: 0.40, blue: 0.98)
        case "ultra-lite": return Color(red: 0.50, green: 0.45, blue: 0.95)
        case "free": return .secondary
        case "business": return .mint
        default: return .secondary
        }
    }
}

private struct MetaTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 0.7))
    }
}

struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .foregroundStyle(.primary)
            .quotaGlass(cornerRadius: 99, tint: configuration.isPressed ? AppPalette.aqua.opacity(0.12) : .clear, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct ConcentricRefreshIcon: View {
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                ConcentricSpinner()
                    .transition(.opacity)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .transition(.opacity)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeInOut(duration: 0.18), value: isLoading)
    }
}

private struct ConcentricSpinner: View {
    @UIState private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color.primary.opacity(0.15),
                        Color.primary.opacity(0.9)
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

extension View {
    func quotaGlass(cornerRadius: CGFloat, tint: Color, interactive: Bool = false) -> some View {
        glassEffect(
            .regular.tint(tint).interactive(interactive),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

// MARK: - Brand Badge Icons

enum BrandIconAssets {
    static func image(for pool: AccountPoolType, mono: Bool = false) -> NSImage {
        let cacheKey = "\(pool.rawValue)_\(mono)"
        if let cached = cache[cacheKey] { return cached }

        // 1. 尝试从 Bundle Resources 读取
        if !mono {
            if let url = Bundle.main.url(forResource: pool.rawValue, withExtension: "svg", subdirectory: "Icons") ??
                         Bundle.main.url(forResource: pool.rawValue, withExtension: "svg"),
               let data = try? Data(contentsOf: url),
               let img = NSImage(data: data) {
                img.size = NSSize(width: 24, height: 24)
                if pool == .openai { img.isTemplate = true }
                cache[cacheKey] = img
                return img
            }
        }

        // 2. 内嵌官方正版 SVG 矢量数据无缝加载与兜底
        let svgString: String
        switch pool {
        case .openai:
            svgString = openaiSVG
        case .gemini:
            svgString = mono ? geminiMonoSVG : geminiColorSVG
        case .claude:
            svgString = mono ? claudeMonoSVG : claudeColorSVG
        }

        if let data = svgString.data(using: .utf8), let img = NSImage(data: data) {
            img.size = NSSize(width: 24, height: 24)
            if mono || pool == .openai {
                img.isTemplate = true
            }
            cache[cacheKey] = img
            return img
        }

        let fallback = NSImage(size: NSSize(width: 24, height: 24))
        cache[cacheKey] = fallback
        return fallback
    }

    private static var cache: [String: NSImage] = [:]

    static let openaiSVG = """
<svg fill="currentColor" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>OpenAI</title><path d="M21.55 10.004a5.416 5.416 0 00-.478-4.501c-1.217-2.09-3.662-3.166-6.05-2.66A5.59 5.59 0 0010.831 1C8.39.995 6.224 2.546 5.473 4.838A5.553 5.553 0 001.76 7.496a5.487 5.487 0 00.691 6.5 5.416 5.416 0 00.477 4.502c1.217 2.09 3.662 3.165 6.05 2.66A5.586 5.586 0 0013.168 23c2.443.006 4.61-1.546 5.361-3.84a5.553 5.553 0 003.715-2.66 5.488 5.488 0 00-.693-6.497v.001zm-8.381 11.558a4.199 4.199 0 01-2.675-.954c.034-.018.093-.05.132-.074l4.44-2.53a.71.71 0 00.364-.623v-6.176l1.877 1.069c.02.01.033.029.036.05v5.115c-.003 2.274-1.87 4.118-4.174 4.123zM4.192 17.78a4.059 4.059 0 01-.498-2.763c.032.02.09.055.131.078l4.44 2.53c.225.13.504.13.73 0l5.42-3.088v2.138a.068.068 0 01-.027.057L9.9 19.288c-1.999 1.136-4.552.46-5.707-1.51h-.001zM3.023 8.216A4.15 4.15 0 015.198 6.41l-.002.151v5.06a.711.711 0 00.364.624l5.42 3.087-1.876 1.07a.067.067 0 01-.063.005l-4.489-2.559c-1.995-1.14-2.679-3.658-1.53-5.63h.001zm15.417 3.54l-5.42-3.088L14.896 7.6a.067.067 0 01.063-.006l4.489 2.557c1.998 1.14 2.683 3.662 1.529 5.633a4.163 4.163 0 01-2.174 1.807V12.38a.71.71 0 00-.363-.623zm1.867-2.773a6.04 6.04 0 00-.132-.078l-4.44-2.53a.731.731 0 00-.729 0l-5.42 3.088V7.325a.068.068 0 01.027-.057L14.1 4.713c2-1.137 4.555-.46 5.707 1.513.487.833.664 1.809.499 2.757h.001zm-11.741 3.81l-1.877-1.068a.065.065 0 01-.036-.051V6.559c.001-2.277 1.873-4.122 4.181-4.12.976 0 1.92.338 2.671.954-.034.018-.092.05-.131.073l-4.44 2.53a.71.71 0 00-.365.623l-.003 6.173v.002zm1.02-2.168L12 9.25l2.414 1.375v2.75L12 14.75l-2.415-1.375v-2.75z"/></svg>
"""

    static let geminiColorSVG = """
<svg height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>Gemini</title><defs><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-fill-0" x1="7" x2="11" y1="15.5" y2="12"><stop stop-color="#08B962"/><stop offset="1" stop-color="#08B962" stop-opacity="0"/></linearGradient><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-fill-1" x1="8" x2="11.5" y1="5.5" y2="11"><stop stop-color="#F94543"/><stop offset="1" stop-color="#F94543" stop-opacity="0"/></linearGradient><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-fill-2" x1="3.5" x2="17.5" y1="13.5" y2="12"><stop stop-color="#FABC12"/><stop offset=".46" stop-color="#FABC12" stop-opacity="0"/></linearGradient></defs><path d="M20.616 10.835a14.147 14.147 0 0 1 -4.45-3.001 14.111 14.111 0 0 1 -3.678-6.452.503.503 0 0 0 -.975 0 14.134 14.134 0 0 1 -3.679 6.452 14.155 14.155 0 0 1 -4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 0 0 0 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 0 1 4.45 3.001 14.112 14.112 0 0 1 3.679 6.453.502.502 0 0 0 .975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 0 1 3.001-4.45 14.113 14.113 0 0 1 6.453-3.678.503.503 0 0 0 0-.975 13.245 13.245 0 0 1 -2.003-.678z" fill="#3186FF"/><path d="M20.616 10.835a14.147 14.147 0 0 1 -4.45-3.001 14.111 14.111 0 0 1 -3.678-6.452.503.503 0 0 0 -.975 0 14.134 14.134 0 0 1 -3.679 6.452 14.155 14.155 0 0 1 -4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 0 0 0 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 0 1 4.45 3.001 14.112 14.112 0 0 1 3.679 6.453.502.502 0 0 0 .975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 0 1 3.001-4.45 14.113 14.113 0 0 1 6.453-3.678.503.503 0 0 0 0-.975 13.245 13.245 0 0 1 -2.003-.678z" fill="url(#lobe-icons-gemini-fill-0)"/><path d="M20.616 10.835a14.147 14.147 0 0 1 -4.45-3.001 14.111 14.111 0 0 1 -3.678-6.452.503.503 0 0 0 -.975 0 14.134 14.134 0 0 1 -3.679 6.452 14.155 14.155 0 0 1 -4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 0 0 0 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 0 1 4.45 3.001 14.112 14.112 0 0 1 3.679 6.453.502.502 0 0 0 .975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 0 1 3.001-4.45 14.113 14.113 0 0 1 6.453-3.678.503.503 0 0 0 0-.975 13.245 13.245 0 0 1 -2.003-.678z" fill="url(#lobe-icons-gemini-fill-1)"/><path d="M20.616 10.835a14.147 14.147 0 0 1 -4.45-3.001 14.111 14.111 0 0 1 -3.678-6.452.503.503 0 0 0 -.975 0 14.134 14.134 0 0 1 -3.679 6.452 14.155 14.155 0 0 1 -4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 0 0 0 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 0 1 4.45 3.001 14.112 14.112 0 0 1 3.679 6.453.502.502 0 0 0 .975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 0 1 3.001-4.45 14.113 14.113 0 0 1 6.453-3.678.503.503 0 0 0 0-.975 13.245 13.245 0 0 1 -2.003-.678z" fill="url(#lobe-icons-gemini-fill-2)"/></svg>
"""

    static let geminiMonoSVG = """
<svg height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>Gemini</title><path d="M20.616 10.835a14.147 14.147 0 0 1 -4.45-3.001 14.111 14.111 0 0 1 -3.678-6.452.503.503 0 0 0 -.975 0 14.134 14.134 0 0 1 -3.679 6.452 14.155 14.155 0 0 1 -4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 0 0 0 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 0 1 4.45 3.001 14.112 14.112 0 0 1 3.679 6.453.502.502 0 0 0 .975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 0 1 3.001-4.45 14.113 14.113 0 0 1 6.453-3.678.503.503 0 0 0 0-.975 13.245 13.245 0 0 1 -2.003-.678z" fill="currentColor"/></svg>
"""

    static let claudeColorSVG = """
<svg height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>Claude</title><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z" fill="#D97757" fill-rule="nonzero"/></svg>
"""

    static let claudeMonoSVG = """
<svg height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>Claude</title><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z" fill="currentColor" fill-rule="nonzero"/></svg>
"""
}

struct ProviderBrandIcon: View {
    let pool: AccountPoolType
    let isSelected: Bool
    var mono: Bool = false

    var body: some View {
        let nsImage = BrandIconAssets.image(for: pool, mono: mono)
        Image(nsImage: nsImage)
            .renderingMode(mono || pool == .openai ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(foregroundColor)
            .opacity(isSelected || mono ? 1.0 : 0.65)
    }

    private var foregroundColor: Color {
        if mono { return .white }
        switch pool {
        case .openai:
            return isSelected ? Color(red: 0.08, green: 0.72, blue: 0.55) : .secondary
        case .gemini, .claude:
            return .primary
        }
    }
}
