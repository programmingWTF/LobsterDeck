import WebKit
import UIKit
import SwiftUI

struct ReportsView: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var showShared = false

    private var filtered: [Report] {
        guard !query.isEmpty else { return state.reports }
        return state.reports.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if filtered.isEmpty {
                        GlassCard { EmptyHint(icon: "doc.text.magnifyingglass", text: "没有找到报告") }
                            .padding(.top, 20)
                    } else {
                        GlassEffectContainer(spacing: 14) {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { r in
                                    NavigationLink(value: Route.report(r.id)) {
                                        ReportRow(report: r)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await state.refreshReports() }
            .navigationTitle("报告")
            .deckTopBar()
            .searchable(text: $query, prompt: "搜索报告")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showShared = true } label: {
                        Image(systemName: "lock.open")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .sheet(isPresented: $showShared) {
                SharedReportsSheet()
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .report(let id): ReportDetailView(reportID: id)
                default: EmptyView()
                }
            }
        }
    }
}

struct ReportRow: View {
    let report: Report

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.lobster.opacity(0.22), Color.lobster.opacity(0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 42, height: 42)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.lobster)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(report.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(report.date ?? "")
                    if report.shared == true {
                        Label("共享中", systemImage: "lock.open.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            RowChevron()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.lobster.opacity(0.06)).interactive(), in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }
}

// MARK: - Reader

struct ReportDetailView: View {
    let reportID: String
    @Environment(AppState.self) private var state

    @State private var html: String?
    @State private var error: String?
    @State private var showShare = false

    private var report: Report? { state.reports.first { $0.id == reportID } }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            if let html {
                ReportWebView(html: html, baseURL: assetsURL)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.glass)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(report?.title ?? "报告")
        .navigationBarTitleDisplayMode(.inline)
        .deckTopBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let report {
                ReportTokenSheet(report: report)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .task { await load() }
    }

    private var assetsURL: URL? {
        guard let api = try? state.client() else { return nil }
        return api.base.appendingPathComponent("api/v1/report-assets/reports/")
    }

    private func load() async {
        error = nil
        do {
            let res: ReportHTML = try await state.client().get("/api/v1/reports/\(reportID)/html")
            html = res.html
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReportWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = true
        wv.backgroundColor = .white
        wv.scrollView.backgroundColor = .white
        wv.underPageBackgroundColor = .white
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            wv.loadHTMLString(Self.styled(html), baseURL: baseURL)
        }
    }

    /// Reports were written for a desktop browser: no viewport meta, no
    /// guaranteed background. Force a light canvas and keep media inside the
    /// screen, without touching each report's own colours and layout.
    private static func styled(_ html: String) -> String {
        let head = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <style>
        html{background:#ffffff;color-scheme:light;-webkit-text-size-adjust:100%;}
        html,body{max-width:100%;overflow-x:hidden;}
        img,video,svg{max-width:100%;height:auto;}
        table{max-width:100%;}
        pre{overflow-x:auto;}
        </style>
        """
        if let r = html.range(of: "<head>", options: [.caseInsensitive]) {
            return html.replacingCharacters(in: r, with: "<head>" + head)
        }
        return head + html
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               url.scheme == "http" || url.scheme == "https" {
                var target = url
                if url.path.hasPrefix("/api/v1/report-assets/") {
                    let rel = url.path.replacingOccurrences(of: "/api/v1/report-assets/", with: "")
                    if let mapped = URL(string: "https://reports.liguiyu.com/" + rel) { target = mapped }
                }
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}


struct SharedReportsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var active: Report?

    private var shared: [Report] { state.reports.filter { $0.shared == true } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if shared.isEmpty {
                        GlassCard { EmptyHint(icon: "lock", text: "还没有共享中的报告") }
                    } else {
                        ForEach(shared) { r in
                            Button { active = r } label: { ReportRow(report: r) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("共享管理")
            .navigationBarTitleDisplayMode(.inline)
            .deckTopBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .sheet(item: $active) { r in
                ReportTokenSheet(report: r)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }
}
