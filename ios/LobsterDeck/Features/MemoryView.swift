import SwiftUI
import WebKit

struct MemoryView: View {
    var body: some View {
        NavigationStack {
            MemoryBrowser(path: "")
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .memory(let p): MemoryBrowser(path: p)
                    case .memoryFile(let p): MemoryFileView(path: p)
                    default: EmptyView()
                    }
                }
        }
    }
}

struct MemoryBrowser: View {
    let path: String
    @Environment(AppState.self) private var state

    @State private var listing: MemoryListing?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let listing {
                    if !listing.dirs.isEmpty {
                        SoftList {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(listing.dirs.enumerated()), id: \.element.id) { idx, d in
                                    NavigationLink(value: Route.memory(d.path)) {
                                        HStack(spacing: 12) {
                                            Image(systemName: d.name == "Memory" ? "brain.head.profile" : "folder.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(Color.lobster)
                                                .frame(width: 28)
                                            Text(d.name).font(.subheadline)
                                            Spacer()
                                            RowChevron()
                                        }
                                        .padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if idx < listing.dirs.count - 1 {
                                        Divider().opacity(0.25).padding(.leading, 40)
                                    }
                                }
                            }
                        }
                    }

                    if !listing.files.isEmpty {
                        SoftList {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(listing.files.enumerated()), id: \.element.id) { idx, f in
                                    NavigationLink(value: Route.memoryFile(f.path)) {
                                        HStack(spacing: 12) {
                                            Image(systemName: iconFor(f))
                                                .font(.system(size: 14))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 28)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(f.name).font(.subheadline).lineLimit(2)
                                                Text("\(f.sizeH ?? "") · \(Fmt.day(f.mtime))")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 4)
                                            RowChevron()
                                        }
                                        .padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if idx < listing.files.count - 1 {
                                        Divider().opacity(0.25).padding(.leading, 40)
                                    }
                                }
                            }
                        }
                    }

                    if listing.dirs.isEmpty && listing.files.isEmpty {
                        SoftList { EmptyHint(icon: "brain", text: "这里还没有记忆文件") }
                    }
                } else if let error {
                    SoftList {
                        VStack(spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试") { Task { await load() } }.buttonStyle(.glass)
                        }
                    }
                } else {
                    SoftList { EmptyHint(icon: "hourglass", text: "读取中…") }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .deckTitle(path.isEmpty ? "记忆库" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: path) { await load() }
    }

    private func load() async {
        do {
            listing = try await state.client().repoTree(path: path)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func iconFor(_ f: MemoryEntry) -> String {
        switch (f.ext ?? "").lowercased() {
        case ".md", ".markdown": return "doc.text"
        case ".json", ".yml", ".yaml", ".toml": return "curlybraces"
        case ".png", ".jpg", ".jpeg", ".svg", ".webp": return "photo"
        case ".sh", ".py", ".js", ".ts", ".swift": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

struct MemoryFileView: View {
    let path: String
    @Environment(AppState.self) private var state

    @State private var file: MemoryFile?
    @State private var error: String?

    var body: some View {
        Group {
            if let file {
                if let html = file.html {
                    MarkdownWebView(html: html)
                } else if let text = file.text {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .deckTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do { file = try await state.client().repoFile(path: path) }
        catch { self.error = error.localizedDescription }
    }
}

struct MarkdownWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            wv.loadHTMLString(Self.page(html), baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: String? }

    private static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root{color-scheme:light;}
        body{font:16px/1.62 -apple-system,"PingFang SC",sans-serif;color:#1c1c1e;background:#fff;
             padding:16px 18px 40px;margin:0;max-width:100%;overflow-x:hidden;}
        h1{font-size:26px;margin:.6em 0 .5em}h2{font-size:21px;margin:1.2em 0 .5em}
        h3{font-size:18px}h4{font-size:16px}
        p{margin:.6em 0}ul,ol{padding-left:1.4em}li{margin:.25em 0}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:#f2f2f4;
             padding:1px 5px;border-radius:5px;font-size:.88em}
        pre{background:#f6f6f8;border-radius:10px;padding:12px;overflow-x:auto}
        pre code{background:none;padding:0}
        blockquote{border-left:3px solid #ddd;margin:.8em 0;padding:.2em .9em;color:#555}
        table{border-collapse:collapse;max-width:100%;display:block;overflow-x:auto}
        th,td{border:1px solid #e3e3e6;padding:6px 9px;font-size:14px}
        img{max-width:100%;height:auto;border-radius:8px}
        a{color:#e8500a;text-decoration:none}
        hr{border:none;border-top:1px solid #eee;margin:1.4em 0}
        </style></head><body>\(body)</body></html>
        """
    }
}
