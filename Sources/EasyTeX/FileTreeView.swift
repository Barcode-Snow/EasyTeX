import SwiftUI
import UniformTypeIdentifiers

struct FileTreeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.root == nil {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30, weight: .light))
                    Text("No folder open")
                        .font(.callout)
                    Button("Open Folder…") { state.chooseFolder() }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.tree, children: \.children, selection: $state.selection) { node in
                    Label(node.name, systemImage: icon(for: node))
                        .lineLimit(1)
                        .contextMenu { menu(for: node) }
                }
                .listStyle(.sidebar)
                .onChange(of: state.selection) { _, url in
                    if let url, !isDirectory(url), state.current != url { state.open(url) }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in state.importDropped(providers) }
                .contextMenu {
                    Button("New File…") { state.promptNewFile(in: state.root) }
                    Button("New Folder…") { state.promptNewFolder(in: state.root) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("New File…") { state.promptNewFile() }
                    Button("New Folder…") { state.promptNewFolder() }
                    Menu("New Project") {
                        ForEach(ProjectTemplate.allCases, id: \.self) { template in
                            Button(template.rawValue) { state.newProject(template) }
                        }
                    }
                    Divider()
                    Button("Open Folder…") { state.chooseFolder() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "tex", "sty", "cls", "ltx": return "doc.text"
        case "bib": return "books.vertical"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "tiff", "heic", "svg": return "photo"
        default: return "doc"
        }
    }

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        if node.isDirectory {
            Button("New File…") { state.promptNewFile(in: node.url) }
            Button("New Folder…") { state.promptNewFolder(in: node.url) }
            Divider()
        }
        Button("Rename…") { state.promptRename(node.url) }
        Button("Show in Finder") { state.reveal(inFinder: node.url) }
        Divider()
        Button("Move to Trash", role: .destructive) { state.moveToTrash(node.url) }
    }
}
