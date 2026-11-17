import SwiftUI

private enum Panel: String, CaseIterable {
    case overview = "概览", settings = "设置"
    var icon: String { self == .overview ? "square.grid.2x2" : "slider.horizontal.3" }
}

private final class WindowState: ObservableObject {
    @Published var panel: Panel = .overview
    @Published var awsPort: String
    @Published var localPort: String
    @Published var saved = false
    init(store: TunnelStore) {
        awsPort = String(store.tunnels[0].port)
        localPort = String(store.tunnels[1].port)
    }
}

private extension Tunnel {
    var statusColor: Color {
        failure != nil ? .red : (desired ? (isConnected ? .green : .orange) : .secondary)
    }
    var statusLabel: String {
        if state == .external { return displayStatus }
        if let failure { return failure.title }
        switch state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "已停止"
        case .failed: return "连接失败"
        case .external: return displayStatus
        }
    }
}

private enum Theme {
    static let accent = Color(red: 0.28, green: 0.36, blue: 0.88)
    static let line = Color.primary.opacity(0.055)
    static let inset = Color.primary.opacity(0.025)
}

private struct Surface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
    }
}

private struct StatusPill: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .fixedSize()
        .foregroundColor(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.09)).clipShape(Capsule())
    }
}

private struct TunnelCard: View {
    @ObservedObject var tunnel: Tunnel
    private var isAWS: Bool { tunnel.host == "aws-proxy" }
    private var accent: Color { isAWS ? Color(red: 0.76, green: 0.49, blue: 0.22) : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isAWS ? "cloud.fill" : "desktopcomputer")
                    .font(.system(size: 16, weight: .medium)).foregroundColor(accent)
                    .frame(width: 34, height: 34).background(accent.opacity(0.09)).cornerRadius(10)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tunnel.name).font(.system(size: 13, weight: .semibold))
                    Text(tunnel.host).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                Spacer()
                StatusPill(label: tunnel.statusLabel, color: tunnel.statusColor)
                Toggle("连接 \(tunnel.name)", isOn: Binding(get: { tunnel.switchIsOn }, set: { enabled in
                    enabled ? tunnel.start() : tunnel.stop()
                }))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent)).labelsHidden()
                .padding(.leading, 6)
            }
            .padding(14)
            HStack(spacing: 12) {
                endpoint("本地入口", port: tunnel.port)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Rectangle().fill(Theme.line).frame(width: 10, height: 1)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                    Rectangle().fill(Theme.line).frame(width: 10, height: 1)
                }.foregroundColor(.secondary.opacity(0.5)).accessibilityHidden(true)
                Spacer(minLength: 0)
                endpoint("远端服务", port: tunnel.remotePort)
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.inset).cornerRadius(10)
                .padding(.horizontal, 14).padding(.bottom, 14)

            if tunnel.state == .external && !tunnel.externalMatches {
                Label("端口由 SSH 监听，但尚无法确认转发目标。", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundColor(.orange)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure = tunnel.failure {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(failure.advice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if let retryMessage = tunnel.retryMessage {
                                Text(retryMessage).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("重试") { tunnel.start() }
                            .disabled(tunnel.occupiesPort)
                    }
                    HStack {
                        Button {
                            let text = "\(tunnel.name) · \(failure.title)\n\(failure.advice)\n\n\(failure.diagnostic)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        } label: {
                            Label("复制错误", systemImage: "doc.on.doc")
                        }
                        .help("复制错误类型、排查建议和完整原始错误")
                        Spacer()
                        Button(tunnel.waitingForPort ? "取消重试" : "清除错误") { tunnel.stop() }
                    }
                    DisclosureGroup("查看原始错误") {
                        Text(failure.diagnostic).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }.font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(16).background(Color.red.opacity(0.045))
            }
        }.modifier(Surface())
    }

    private func endpoint(_ label: String, port: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("127.0.0.1").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Text(verbatim: String(port)).font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
                .textSelection(.enabled)
        }
    }
}

struct DetailsView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject private var ui: WindowState

    init(store: TunnelStore) {
        self.store = store
        _ui = ObservedObject(wrappedValue: WindowState(store: store))
    }
    private var online: Int { store.tunnels.filter { $0.isConnected }.count }
    private var failures: Int { store.tunnels.filter { $0.failure != nil }.count }
    private var active: Bool { store.tunnels.contains { $0.desired } }
    private var error: String? { TunnelStore.portError(ui.awsPort, ui.localPort) }
    private var summary: String {
        if failures > 0 { return "有 \(failures) 个隧道需要处理" }
        if store.tunnels.contains(where: { $0.state == .external && !$0.externalMatches }) { return "连接待确认" }
        return online > 0 ? "连接已就绪" : (active ? "正在建立连接" : "所有隧道已停止")
    }
    private var summaryColor: Color { failures > 0 ? .red : (online > 0 ? .green : (active ? .orange : .secondary)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 28, height: 28)
                Text("Portly").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("页面", selection: $ui.panel) {
                    ForEach(Panel.allCases, id: \.self) { panel in
                        Text(panel.rawValue).tag(panel)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ui.panel == .overview { overview } else { settings }
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(Theme.accent)
        .textSelection(.enabled)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 500)
        .onChange(of: ui.awsPort) { _ in ui.saved = false }
        .onChange(of: ui.localPort) { _ in ui.saved = false }
    }

    private var overview: some View {
        Group {
            HStack(spacing: 7) {
                Circle().fill(summaryColor).frame(width: 6, height: 6)
                Text(summary).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text("\(online) / 2 已连接").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }.padding(.bottom, 2)
            ForEach(store.tunnels, id: \.host) { TunnelCard(tunnel: $0) }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("关闭窗口继续运行 · 退出 Portly 断开连接")
            }.font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2)
        }
    }

    private var settings: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundColor(Theme.accent)
                    Text("本地端口").font(.system(size: 14, weight: .semibold))
                }.padding(14)
                Divider()
                portRow("AWS Proxy", host: "aws-proxy", value: $ui.awsPort)
                Divider().padding(.horizontal, 14)
                portRow("Local Proxy", host: "local-proxy", value: $ui.localPort)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundColor(.red).font(.system(size: 12))
                    }
                    if active {
                        Label("请先停止两个隧道，再保存端口设置。", systemImage: "lock")
                            .foregroundColor(.secondary).font(.system(size: 12))
                    }
                    HStack {
                        Text("仅修改本地端口，远端服务地址不变。")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        if ui.saved { Label("已保存", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(.green) }
                        Button("保存设置") { ui.saved = store.savePorts(ui.awsPort, ui.localPort) }
                            .buttonStyle(.borderedProminent).disabled(active || error != nil)
                    }
                }.padding(14)
            }.modifier(Surface())
            Label("端口冲突最多自动重试 2 次，可在故障卡片中取消。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2)
        }
    }

    private func portRow(_ title: String, host: String, value: Binding<String>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(host).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            Spacer()
            Text("127.0.0.1 :").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            TextField("端口", text: value).textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8).frame(width: 84)
                .background(Theme.inset).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? Color.primary.opacity(0.08) : Color.red.opacity(0.6), lineWidth: 1))
                .accessibilityLabel("\(title) 本地端口")
        }.padding(14)
    }
}
