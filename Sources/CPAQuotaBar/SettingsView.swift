#if canImport(CPAQuotaCore)
import CPAQuotaCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.28)

            ScrollView {
                LazyVStack(spacing: 12) {
                    connectionCard
                    updateCard
                    quotaPolicyCard
                    refreshCard
                    accountOverrideCard

                    if let error = model.errorMessage,
                       case .failure = model.connectionTestState {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)

            VStack(alignment: .leading, spacing: 1) {
                Text("设置").font(.headline.weight(.semibold))
                Text("连接与监控策略").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("保存") {
                Task { if await model.saveSettings() { close() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving)
            Button { model.quit() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusable(false)
            .help("退出 CPA Quota Bar")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var connectionCard: some View {
        SettingsCard(title: "连接", icon: "network") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsTextField(
                    label: "CPA 地址",
                    placeholder: "http://127.0.0.1:8317",
                    text: $model.address
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Management Key").font(.caption).foregroundStyle(.secondary)
                    SecureField("输入 Management Key", text: $model.managementKey)
                        .textFieldStyle(.roundedBorder)
                    Label("保存在此应用的本机偏好中，不使用钥匙串", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if model.address.lowercased().hasPrefix("http://"),
                   !model.address.contains("127.0.0.1"),
                   !model.address.contains("localhost") {
                    Label("提示：若连接远程公网服务器，建议使用 HTTPS", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    connectionTestFeedback
                    Spacer(minLength: 8)
                    Button {
                        Task { await model.testConnection() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.connectionTestState == .testing {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.connectionTestState == .testing ? "测试中…" : "测试连接")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.connectionTestState == .testing)
                }
            }
        }
    }

    private var updateCard: some View {
        SettingsCard(title: "应用更新", icon: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 9) {
                Text(updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: updateAction) {
                    HStack(spacing: 7) {
                        if case .checking = model.updateState {
                            ProgressView().controlSize(.small)
                        } else if case .downloading = model.updateState {
                            ProgressView().controlSize(.small)
                        }
                        Text(updateButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.updateState == .checking || isDownloading)
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = model.updateState { return true }
        return false
    }

    private var updateButtonTitle: String {
        switch model.updateState {
        case .available(let info): return "更新到 v\(info.version)"
        case .checking: return "检查中…"
        case .downloading: return "正在更新…"
        case .upToDate: return "重新检查"
        case .failed: return "重试检查"
        case .downloaded: return "已完成更新"
        case .idle: return "检查更新"
        }
    }

    private var updateDescription: String {
        switch model.updateState {
        case .available(let info): return "发现新版本 v\(info.version)，点击更新后应用会自动重启。"
        case .checking: return "正在检查 GitHub Releases…"
        case .downloading: return "正在下载并校验新版本，完成后会自动重启。"
        case .upToDate: return "当前已是最新版本。"
        case .failed(let message): return "检查更新失败：\(message)"
        case .downloaded: return "更新已完成。"
        case .idle: return "启动时会自动检查，也可以手动检查。"
        }
    }

    private func updateAction() {
        switch model.updateState {
        case let .available(info):
            Task { await model.downloadUpdate(info) }
        case .downloading, .checking, .downloaded:
            break
        default:
            Task { await model.checkForUpdates() }
        }
    }

    private var quotaPolicyCard: some View {
        SettingsCard(title: "额度策略", icon: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("达到阈值时自动禁用账号", isOn: $model.monitorSettings.enabled)

                HStack {
                    Text("禁用阈值")
                    Spacer()
                    TextField("10", value: $model.monitorSettings.remainingThresholdPercent, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("%").foregroundStyle(.secondary)
                }
                .font(.subheadline)

                Label("只恢复由本应用自动禁用的账号，不会改动手动禁用状态", systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var refreshCard: some View {
        SettingsCard(title: "刷新节奏", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    DurationField(label: "会话活跃", value: $model.monitorSettings.refreshInterval, hint: "1m")
                    DurationField(label: "会话空闲", value: $model.monitorSettings.idleRefreshInterval, hint: "1h")
                }
                DurationField(label: "无新请求后进入空闲", value: $model.monitorSettings.idleAfter, hint: "5m")
                Text("后台每分钟轻量检测请求活动；仅在活跃期或空闲周期到期时查询完整额度。支持 m、h、d。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var accountOverrideCard: some View {
        SettingsCard(title: "账号覆盖", icon: "person.crop.circle.badge.checkmark") {
            VStack(alignment: .leading, spacing: 7) {
                Text("每行一个账号、认证 ID 或邮箱，格式为 account=percent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.overridesText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 82)
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var connectionTestFeedback: some View {
        switch model.connectionTestState {
        case .idle, .testing:
            EmptyView()
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
        case let .failure(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct SettingsPickerLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

private struct DurationField: View {
    let label: String
    @Binding var value: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: $value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content
        }
        .font(.caption)
        .padding(14)
        .quotaGlass(cornerRadius: 18, tint: .accentColor.opacity(0.035))
    }
}
