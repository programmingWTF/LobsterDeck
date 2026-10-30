import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    private var urlBinding: Binding<String> {
        Binding(get: { state.serverURL }, set: { state.serverURL = $0 })
    }
    private var tokenBinding: Binding<String> {
        Binding(get: { state.token }, set: { state.token = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: urlBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("访问令牌", text: tokenBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("连接")
                } footer: {
                    Text("令牌保存在本机钥匙串。服务器地址支持局域网 http 或公网 https。")
                }

                Section {
                    Button {
                        Task {
                            testing = true
                            let err = await state.testConnection()
                            testOK = (err == nil)
                            testResult = err ?? "连接成功 · API \(state.healthVersion ?? "")"
                            testing = false
                            if err == nil { await state.refreshAll() }
                        }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "正在测试" : "测试连接")
                        }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testOK ? Color.green : Color.red)
                    }
                }

                Section("服务") {
                    linkRow("报告台", "reports.liguiyu.com", "https://reports.liguiyu.com")
                    linkRow("文件站", "file.liguiyu.com", "https://file.liguiyu.com/fs")
                    linkRow("Agent 看板", "agent.liguiyu.com", "https://agent.liguiyu.com")
                }

                Section {
                    HStack {
                        Text("客户端版本")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("首页布局")
                        Spacer()
                        Text(state.overview?.generatedBy ?? "lobster").foregroundStyle(.secondary)
                    }
                    if let t = state.overview?.layoutUpdatedAt {
                        HStack {
                            Text("布局更新")
                            Spacer()
                            Text(Fmt.relative(t)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("首页模块与尺寸由 Agent 通过 /api/v1/home/layout 编排，App 只负责渲染。")
                }

                Section {
                    Button(role: .destructive) {
                        state.token = ""
                        Keychain.delete("api.token")
                        state.overview = nil
                        dismiss()
                    } label: {
                        Text("断开连接")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .deckTopBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func linkRow(_ title: String, _ subtitle: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
