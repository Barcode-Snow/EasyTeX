import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            // The system toolbar band starts a few points inside the sidebar (it overlaps it),
            // so hide it and let the detail column paint the band itself, starting exactly at its edge.
            // A SwiftUI split (not HSplitView, whose AppKit divider reaches up into the title bar).
            EditorPDFSplit()
                .overlay(alignment: .top) { Divider() }
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(.bar)
        }
        .navigationTitle(state.windowTitle)
        .navigationSubtitle(state.root?.lastPathComponent ?? "")
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.texSetupVisible) { TeXSetupSheet() }
        .onAppear { state.startup() }
        .onChange(of: colorScheme, initial: true) { _, scheme in state.editor.setTheme(dark: scheme == .dark) }
        .onChange(of: state.showTree) { _, show in columns = show ? .all : .detailOnly }
        .onChange(of: columns) { _, value in
            let visible = value != .detailOnly
            if state.showTree != visible { state.showTree = visible }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) { StatusLabel() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.saveAndCompile() } label: {
                Label("Compile", systemImage: "play.fill")
            }
            .help("Save and compile (⌘S)")
            .disabled(state.status == .compiling)

            Button { state.jumpToPDF() } label: {
                Label("Show in PDF", systemImage: "arrow.right.doc.on.clipboard")
            }
            .help("Jump from the cursor to the PDF (⌘J). Double-click the PDF to jump back to the source.")

            Menu {
                Button("Export PDF…") { state.exportPDF() }
                Button("Open in Preview") { state.openPDFInPreview() }
            } label: {
                Label("PDF", systemImage: "square.and.arrow.up")
            }

            Button { state.showProblems.toggle() } label: {
                Label("Problems and Log", systemImage: "exclamationmark.bubble")
            }
            .help("Show problems and compile log (⇧⌘L)")

            Button { state.showPDF.toggle() } label: {
                Label("PDF Preview", systemImage: "sidebar.right")
            }
            .help("Show or hide the PDF preview (⇧⌘P)")
        }
    }
}

/// Editor on the left, PDF on the right, with a draggable divider that stays below the toolbar.
struct EditorPDFSplit: View {
    @EnvironmentObject var state: AppState
    @AppStorage("pdfWidthFraction") private var pdfFraction = 0.5
    @State private var dragStartWidth: CGFloat?

    private let editorMin: CGFloat = 340
    private let pdfMin: CGFloat = 280

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let pdfWidth = clampedPDFWidth(total * pdfFraction, total: total)
            HStack(spacing: 0) {
                EditorColumn()
                    .frame(maxWidth: .infinity)
                if state.showPDF {
                    Divider()
                        .overlay {
                            // Wider invisible grab area around the 1pt line.
                            Color.clear
                                .frame(width: 8)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let start = dragStartWidth ?? pdfWidth
                                            if dragStartWidth == nil { dragStartWidth = start }
                                            let width = clampedPDFWidth(start - value.translation.width, total: total)
                                            pdfFraction = Double(width / max(total, 1))
                                        }
                                        .onEnded { _ in dragStartWidth = nil }
                                )
                        }
                    PDFPane()
                        .frame(width: pdfWidth)
                }
            }
        }
    }

    private func clampedPDFWidth(_ width: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(pdfMin, total - editorMin - 1)
        return min(max(width, pdfMin), upper)
    }
}

struct StatusLabel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.status {
        case .idle:
            EmptyView()
        case .compiling:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Compiling…").font(.callout).foregroundStyle(.secondary)
            }
        case .ok:
            Label("Compiled", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed:
            let count = state.diagnostics.filter { $0.kind == .error }.count
            Label(count == 1 ? "1 error" : "\(count) errors", systemImage: "xmark.octagon.fill")
                .font(.callout).foregroundStyle(.red)
        }
    }
}

// MARK: - Editor column: tabs, editor, problems

struct EditorColumn: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.openFiles.isEmpty { TabBar() }
            ZStack {
                EditorWebView()
                    .opacity(showsEditor ? 1 : 0)
                if let url = state.current, state.isPreview(url) {
                    PreviewPane(url: url)
                } else if state.current == nil {
                    EmptyEditor()
                }
            }
            if state.showProblems {
                Divider()
                ProblemsPanel()
                    .frame(height: 170)
            }
        }
    }

    private var showsEditor: Bool {
        guard let url = state.current else { return false }
        return !state.isPreview(url)
    }
}

struct EmptyEditor: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light))
            Text(state.root == nil ? "Open a folder to get started" : "Select a file in the sidebar")
                .font(.title3)
            if state.root == nil {
                Button("Open Folder…") { state.chooseFolder() }
                    .controlSize(.large)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }
}

struct PreviewPane: View {
    let url: URL

    var body: some View {
        Group {
            if url.pathExtension.lowercased() == "pdf" {
                StaticPDFView(url: url)
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else {
                Text("Can't preview this file").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }
}

struct TabBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(state.openFiles, id: \.self) { url in
                    TabItem(url: url)
                }
            }
        }
        .frame(height: 30)
        .background(.bar, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabItem: View {
    @EnvironmentObject var state: AppState
    let url: URL
    @State private var hovering = false

    var body: some View {
        let isCurrent = state.current == url
        let isDirty = state.dirty.contains(url)
        HStack(spacing: 6) {
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
            ZStack {
                if isDirty && !hovering {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                } else {
                    Button { state.closeTab(url) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || isCurrent ? 1 : 0)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isCurrent ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentColor).frame(height: 2).opacity(isCurrent ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.activate(url) }
        .onHover { hovering = $0 }
    }
}

// MARK: - Problems and log

struct ProblemsPanel: View {
    @EnvironmentObject var state: AppState
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showLog) {
                    Text("Problems (\(state.diagnostics.count))").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Button { state.showProblems = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if showLog {
                ScrollView {
                    Text(state.rawLog.isEmpty ? "No log yet." : state.rawLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            } else if state.diagnostics.isEmpty {
                Text(state.status == .idle ? "Nothing compiled yet." : "No problems.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.diagnostics) { item in
                    Button { state.reveal(item) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.kind == .error ? Color.red : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.message).font(.callout).lineLimit(3)
                                if let line = item.line {
                                    Text("\(item.file?.lastPathComponent ?? "") line \(line)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
