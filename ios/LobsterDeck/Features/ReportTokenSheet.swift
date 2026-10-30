import SwiftUI
import UIKit

struct ReportTokenSheet: View {
    let report: Report
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var token: String?
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmRevoke = false

    private var link: String? {
        guard let token else { return nil }
        return "https://reports.liguiyu.com/reports/\(report.id)?t=\(token)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    if token != nil { linkCard }
                    actionButtons
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("撤销后链接立刻失效。修改会写入报告台的 token 表并热重载 nginx，不影响其他报告。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(18)
            }
            .navigationTitle("分享与 Token")
            .navigationBarTitleDisplayMode(.inline)
            .deckTopBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadToken() }
            .confirmationDialog("撤销后旧链接会立即失效", isPresented: $confirmRevoke) {
                Button("撤销共享", role: .destructive) { Task { await act("revoke") } }
            }
        }
    }

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.lobster.opacity(0.16)).frame(width: 46, height: 46)
                    Image(systemName: token == nil ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lobster)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(token == nil ? "未共享" : "共享中")
                        .font(.headline)
                    Text(report.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var linkCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("共享链接").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(link ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = link
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    if let link, let url = URL(string: link) {
                        ShareLink(item: url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if token == nil {
                Button { Task { await act("share") } } label: {
                    Label("生成共享链接", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button { Task { await act("rotate") } } label: {
                    Label("轮换 Token（旧链接失效）", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button(role: .destructive) { confirmRevoke = true } label: {
                    Label("撤销共享", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func loadToken() async {
        do {
            let res: TokenList = try await state.client().get("/api/v1/reports/tokens")
            token = res.tokens[report.id]
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ action: String) async {
        busy = true; error = nil
        do {
            token = try await state.share(report.id, action: action)
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
