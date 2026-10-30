import SwiftUI

@main
struct LobsterDeckApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .tint(.lobster)
                .preferredColorScheme(nil)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AppBackground()
            if state.isConfigured {
                MainTabs()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                SetupView()
            }
        }
        .animation(.smooth(duration: 0.5), value: state.isConfigured)
        .task {
            if state.isConfigured, state.overview == nil {
                await state.refreshAll()
            }
        }
    }
}

struct MainTabs: View {
    @Environment(AppState.self) private var state
    @State private var selection: DeckTab = .home

    enum DeckTab: Hashable { case home, reports, files, memory, agents }

    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "sparkles", value: .home) {
                HomeView(selection: $selection)
            }
            Tab("报告", systemImage: "doc.richtext", value: .reports) {
                ReportsView()
            }
            Tab("文件", systemImage: "folder", value: .files) {
                FilesView()
            }
            Tab("记忆", systemImage: "brain", value: .memory) {
                MemoryView()
            }
            Tab("Agent", systemImage: "brain.head.profile", value: .agents) {
                AgentsView()
            }
        }
        .tint(.lobster)
    }
}

struct SetupView: View {
    @Environment(AppState.self) private var state
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 50)

                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.lobsterSoft, .lobsterDeep],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 88, height: 88)
                            .shadow(color: .lobster.opacity(0.5), radius: 24, y: 10)
                        Text("🦞").font(.system(size: 44))
                    }
                    Text("龙虾驾驶舱")
                        .font(.largeTitle.bold())
                    Text("报告、文件与 Agent 记忆，\n一个属于你的原生空间。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("连接你的 NAS").font(.headline)
                        VStack(spacing: 12) {
                            TextField("https://lobster.example.com", text: Binding(get: { state.serverURL }, set: { state.serverURL = $0 }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding(12)
                                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 14))
                            SecureField("访问令牌", text: Binding(get: { state.token }, set: { state.token = $0 }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 14))
                        }
                        Button {
                            Task {
                                testing = true
                                message = await state.testConnection()
                                if message == nil { await state.refreshAll() }
                                testing = false
                            }
                        } label: {
                            HStack {
                                if testing { ProgressView().controlSize(.small) }
                                Text(testing ? "正在连接" : "测试并进入")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)

                        if let message {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 22)

                Text("令牌只保存在本机钥匙串，不会上传到任何第三方。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 40)
            }
        }
    }
}
