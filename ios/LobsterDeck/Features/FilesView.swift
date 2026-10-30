import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.recentFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "最近变化", subtitle: "文件站里最新落下的东西")
                            GlassEffectContainer(spacing: 12) {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 12) {
                                        ForEach(state.recentFiles) { f in
                                            NavigationLink(value: Route.file(f.path)) {
                                                RecentFileCard(file: f)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                                .scrollIndicators(.hidden)
                            }
                        }
                    }

                    FileBrowserView(path: "", scrolls: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await state.refreshAll() }
            .navigationTitle("文件")
            .deckTopBar()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .folder(let p): FileBrowserView(path: p, scrolls: true)
                case .file(let p): FilePreviewScreen(path: p)
                default: EmptyView()
                }
            }
        }
    }
}

struct RecentFileCard: View {
    let file: FileEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon(file.name))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.lobster)
                Spacer()
                if file.new == true {
                    Text("NEW")
                        .font(.system(size: 8, weight: .black))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.lobster, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            Text(file.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(file.sizeH ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 168, height: 118, alignment: .topLeading)
        .glassEffect(.regular.tint(Color.lobster.opacity(0.10)).interactive(), in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }

    private func icon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "heic", "webp": return "photo"
        case "zip", "7z", "rar": return "archivebox"
        case "md", "txt": return "text.alignleft"
        default: return "doc"
        }
    }
}

struct FileBrowserView: View {
    let path: String
    var scrolls: Bool = true
    @Environment(AppState.self) private var state

    @State private var listing: FileListing?
    @State private var error: String?
    @State private var importing = false
    @State private var uploading = false
    @State private var notice: String?

    var body: some View {
        Group {
            if scrolls {
                ScrollView { content.padding(.horizontal, 16).padding(.bottom, 24) }
                    .scrollIndicators(.hidden)
                    .refreshable { await load() }
            } else {
                content
            }
        }
        .navigationTitle(path.isEmpty ? "文件" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(scrolls ? .inline : .large)
        .deckTopBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: {
                    Image(systemName: uploading ? "arrow.up.circle" : "arrow.up.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .disabled(uploading)
                .accessibilityLabel("上传文件")
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            Task { await handleImport(result) }
        }
        .task(id: path) { await load() }
        .alert("上传", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if uploading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在上传…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let listing {
                if !listing.dirs.isEmpty {
                    SoftList {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(listing.dirs.enumerated()), id: \.element.id) { idx, d in
                                NavigationLink(value: Route.folder(d.path)) {
                                    dirRow(d)
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
                                NavigationLink(value: Route.file(f.path)) {
                                    fileRow(f)
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
                    SoftList { EmptyHint(icon: "folder", text: "这里是空的，可以点右上角上传") }
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
        .padding(.vertical, 2)
    }

    private func dirRow(_ d: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.lobster)
                .frame(width: 28)
            Text(d.name).font(.subheadline)
            Spacer()
            RowChevron()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func fileRow(_ f: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
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

    private func load() async {
        do {
            let res: FileListing = try await state.client().get("/api/v1/files", ["path": path])
            listing = res
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        uploading = true
        var ok = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try await state.client().upload(dir: path, name: url.lastPathComponent, data: data)
                ok += 1
            } catch {
                notice = "\(url.lastPathComponent)：\(error.localizedDescription)"
            }
        }
        uploading = false
        if ok > 0 { await load() }
    }
}

// MARK: - File preview

struct FilePreviewScreen: View {
    let path: String
    @Environment(AppState.self) private var state

    @State private var localURL: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let localURL {
                QuickLookView(url: localURL)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在取回文件…")
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .deckTopBar()
        .toolbar {
            if let localURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: localURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .task { await download() }
    }

    private func download() async {
        do {
            let data = try await state.client().rawFile(path: path)
            let name = (path as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            localURL = url
        } catch { self.error = error.localizedDescription }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
