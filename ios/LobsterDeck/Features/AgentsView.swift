import SwiftUI
import UIKit

private struct AgentTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var agentTint: Color? {
        get { self[AgentTintKey.self] }
        set { self[AgentTintKey.self] = newValue }
    }
}

struct AgentsView: View {
    @Environment(AppState.self) private var state
    @State private var repo: RepoStats?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let repo {
                        // The chart bars inside are the tappable part (tap a
                        // day -> per-agent breakdown below). The container
                        // glass itself was still non-interactive, so tapping
                        // the big card outside the chart felt dead; make it
                        // interactive so the whole card gives press feedback.
                        AgentOverviewCard(repo: repo)
                            .padding(16)
                            .glassEffect(.regular.tint(Color.lobster.opacity(0.08)).interactive(),
                                         in: .rect(cornerRadius: 24))
                    }
                    ForEach(state.agents) { a in
                        NavigationLink(value: Route.agent(a.agent)) {
                            AgentRow(agent: a)
                        }
                        .buttonStyle(.plain)
                    }
                    if state.agents.isEmpty {
                        GlassCard { EmptyHint(icon: "brain", text: "还没有读到 Agent 的记忆变化") }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await state.refreshAgents()
                await loadRepo()
            }
            .deckTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .task { await loadRepo() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .agent(let a): AgentDetailView(agent: a)
                case .commit(let sha, let tint): CommitDetailView(sha: sha, tintHex: tint)
                default: EmptyView()
                }
            }
        }
    }

    private func loadRepo() async {
        do { repo = try await state.client().repoStats() } catch { }
    }
}

struct AgentRow: View {
    let agent: AgentInfo

    private var color: Color { Color(hexString: agent.color) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                AgentAvatar(name: agent.displayName, size: 30, tint: color, icon: agent.icon)
                Text(agent.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text(agent.last == nil ? "暂无活跃" : "活跃 \(Fmt.relative(agent.last))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                stat("COMMITS", agent.commits ?? 0)
                stat("FILES", agent.memoryFiles ?? agent.files ?? 0)
                stat("TOUCHES", agent.touches ?? 0)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(color.opacity(0.22)).interactive(),
                     in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Agent detail

struct AgentCommit: Codable, Identifiable, Equatable {
    var sha: String
    var author: String?
    var date: String?
    var subject: String
    var files: [String]
    var agent: String?

    var id: String { sha }
}

struct AgentCommits: Codable { var items: [AgentCommit] }

struct AgentDetailView: View {
    let agent: String
    @Environment(AppState.self) private var state

    private var color: Color {
        // No theme colour in the server data -> neutral grey, not the
        // global lobster orange. Detail pages must stay white + agent
        // colour only; a missing colour must not invent an orange one.
        Color(hexString: info?.color) ?? .gray
    }

    @State private var commits: [AgentCommit] = []
    @State private var error: String?

    private var info: AgentInfo? { state.agents.first { $0.agent == agent } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header
                ForEach(commits) { c in
                    NavigationLink(value: Route.commit(c.sha, info?.color)) {
                        CommitRow(commit: c, tint: color)
                    }
                    .buttonStyle(.plain)
                }
                if commits.isEmpty && error == nil {
                    // Do NOT reuse GlassCard + EmptyHint here: GlassCard
                    // tints at only 0.16 and EmptyHint draws icon/text in
                    // secondary grey, so the card looked milky/grey, not
                    // theme-coloured. This empty state uses a stronger
                    // theme tint and theme-coloured icon/text so it is
                    // unmistakably the agent's colour.
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(color)
                        Text("这位 Agent 最近没有记忆更新")
                            .font(.footnote)
                            .foregroundStyle(color.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .padding(18)
                    .glassEffect(.regular.tint(color.opacity(0.30)).interactive(),
                                 in: .rect(cornerRadius: Theme.corner))
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(
            ZStack {
                Color(uiColor: .systemBackground)
                LinearGradient(colors: [color.opacity(0.38), color.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        )
        .environment(\.agentTint, color)
        .tint(color)
        .deckTitle(info?.displayName ?? agent, tint: color)
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Detail background stays white + agent colour only; the top
        // itself has no bar layer at all (see deckTitle), only the
        // agent-coloured glass title pill in the middle, not the
        // opaque systemBackground bar that used to look solid black
        // in dark mode. Hide the tab bar, whose glass bar + global
        // orange icon would otherwise leak orange into the detail page.
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private var header: some View {
        GlassCard(tint: color) {
            HStack(spacing: 14) {
                AgentAvatar(name: info?.displayName ?? agent, size: 54,
                            tint: Color(hexString: info?.color),
                            icon: info?.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.displayName ?? agent).font(.headline)
                    Text("最近更新 \(Fmt.relative(info?.last))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(info?.commits30d ?? 0) 次提交 / 30 天")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private func load() async {
        do {
            let res: AgentCommits = try await state.client()
                .get("/api/v1/agents/\(agent)/commits", ["limit": "60"])
            commits = res.items
        } catch { self.error = error.localizedDescription }
    }
}

struct CommitRow: View {
    let commit: AgentCommit
    var tint: Color = .gray

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(commit.sha.prefix(7))
                    .font(.system(.caption2, design: .monospaced))
                Text("·")
                Text(Fmt.relative(commit.date))
                Spacer()
                if !commit.files.isEmpty {
                    Text("\(commit.files.count) 个文件")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.08)).interactive(), in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}

// MARK: - Commit detail

// Wrap icon, drawn with shapes instead of an SF Symbol. The old
// `text.wrap` system image rendered as an empty glass circle in the
// iOS 26 toolbar, so the button looked like glass with no icon at
// all. Drawn bars cannot be blank: two full lines plus a shorter,
// indented third line (the wrapped continuation).
struct WrapIcon: View {
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule().frame(width: 16, height: 2.2)
            Capsule().frame(width: 16, height: 2.2)
            HStack(spacing: 0) {
                Spacer().frame(width: 6)
                Capsule().frame(width: 10, height: 2.2)
            }
        }
        .foregroundStyle(color)
    }
}

struct CommitDetailView: View {
    let sha: String
    @Environment(AppState.self) private var state

    @State private var detail: CommitDetail?
    @State private var error: String?
    @State private var wrapLines = false
    var tintHex: String? = nil
    private var tint: Color? { Color(hexString: tintHex) }

    private var lines: [String] {
        guard let patch = detail?.patch else { return [] }
        return patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d = detail {
                    GlassCard(tint: tint ?? .gray) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.subject ?? "").font(.headline)
                            Text("\(d.author ?? "") · \(Fmt.day(d.date))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let body = d.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(body).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            }
                        }
                    }

                    GlassCard(tint: tint ?? .gray, padding: 0) {
                        if wrapLines {
                            // Auto-wrap: no horizontal scroll, so long
                            // lines wrap to the card width instead of
                            // running off the right edge.
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(lines.prefix(600).enumerated()), id: \.offset) { _, line in
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(color(for: line))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        } else {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(lines.prefix(600).enumerated()), id: \.offset) { _, line in
                                        Text(line.isEmpty ? " " : line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(color(for: line))
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(12)
                            }
                        }
                    }
                    if lines.count > 600 {
                        Text("差异较长，仅显示前 600 行").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(
            ZStack {
                if let tint {
                    Color(uiColor: .systemBackground)
                    LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.06), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else {
                    // No agent colour -> plain system background only.
                    // The old AppBackground fallback leaked the global
                    // orange gradient into a page that must stay white +
                    // agent colour only.
                    Color(uiColor: .systemBackground)
                }
            }
            .ignoresSafeArea()
        )
        .environment(\.agentTint, tint)
        .tint(tint ?? .gray)
        .deckTitle("变更详情", tint: tint ?? .gray)
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Auto-wrap toggle, top right. Same construction as the
            // other pages' topBarTrailing buttons (icon only, 32pt
            // frame), so the system renders it as the same single-layer
            // liquid-glass round button; the icon turns agent-coloured
            // while wrapping is on, so the state is visible at a glance.
            // The icon is WrapIcon (drawn bars), not an SF Symbol: the
            // old text.wrap image rendered blank in the iOS 26 toolbar.
            ToolbarItem(placement: .topBarTrailing) {
                Button { wrapLines.toggle() } label: {
                    WrapIcon(color: wrapLines ? (tint ?? .lobster) : .primary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(wrapLines ? "关闭自动换行" : "自动换行")
            }
        }
        .task { await load() }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .secondary }
        return .primary
    }

    private func load() async {
        do {
            detail = try await state.client().get("/api/v1/agents/commit", ["sha": sha])
        } catch { self.error = error.localizedDescription }
    }
}
