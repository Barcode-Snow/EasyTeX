import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?          // nil for files, so List shows no disclosure arrow
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum ProjectTemplate: String, CaseIterable {
    case article = "Article", report = "Report / Thesis", beamer = "Beamer Presentation"

    var source: String {
        switch self {
        case .article:
            return #"""
            \documentclass[11pt]{article}
            \usepackage{amsmath}
            \usepackage{graphicx}

            \title{Untitled}
            \author{Your Name}
            \date{\today}

            \begin{document}
            \maketitle

            \section{Introduction}
            Hello, EasyTeX!

            \end{document}
            """#
        case .report:
            return #"""
            \documentclass[11pt]{report}
            \usepackage{amsmath}
            \usepackage{graphicx}

            \title{Thesis Title}
            \author{Your Name}
            \date{\today}

            \begin{document}
            \maketitle
            \tableofcontents

            \chapter{Introduction}
            Hello, EasyTeX!

            \end{document}
            """#
        case .beamer:
            return #"""
            \documentclass{beamer}
            \usetheme{default}

            \title{Presentation}
            \author{Your Name}
            \date{\today}

            \begin{document}
            \frame{\titlepage}

            \begin{frame}{First slide}
              Hello, EasyTeX!
            \end{frame}

            \end{document}
            """#
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Project
    @Published var root: URL?
    @Published var tree: [FileNode] = []
    @Published var selection: URL?

    // MARK: Tabs
    @Published var openFiles: [URL] = []
    @Published var current: URL?
    @Published var dirty: Set<URL> = []

    // MARK: Layout
    @Published var showTree = true
    @Published var showPDF = true
    @Published var showProblems = false

    // MARK: Compile
    enum Status { case idle, compiling, ok, failed }
    @Published var status: Status = .idle
    @Published var diagnostics: [Diagnostic] = []
    @Published var rawLog = ""
    @Published var pdfDocument: PDFDocument?
    @Published var texSetupVisible = false
    private(set) var lastMain: URL?
    private var pendingCompile = false
    private var lastSaveTrigger = Date.distantPast

    // MARK: Settings (stored in UserDefaults)
    @Published var appearance: String { didSet { store(appearance, "appearance"); applyAppearance() } }
    @Published var autosave: Bool { didSet { store(autosave, "autosave") } }
    @Published var autoCompile: Bool { didSet { store(autoCompile, "autoCompile") } }
    @Published var fontSize: Int {
        didSet { store(fontSize, "fontSize"); editor.setOptions(["fontSize": fontSize]) }
    }
    @Published var defaultFolder: String? { didSet { store(defaultFolder, "defaultFolder") } }

    // MARK: Collaborators
    let editor = EditorBridge()
    let pdf = PDFController()
    private var cursor: (url: URL, line: Int, column: Int)?
    private var modDates: [URL: Date] = [:]
    private var started = false

    private func store(_ value: Any?, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    private init() {
        let d = UserDefaults.standard
        appearance = d.string(forKey: "appearance") ?? "system"
        autosave = d.object(forKey: "autosave") as? Bool ?? true
        autoCompile = d.object(forKey: "autoCompile") as? Bool ?? false
        fontSize = d.object(forKey: "fontSize") as? Int ?? 13
        defaultFolder = d.string(forKey: "defaultFolder")
        applyAppearance()

        editor.onMessage = { [weak self] msg in self?.handle(msg) }
        pdf.onSourceJump = { [weak self] page, x, y in self?.sourceJump(page: page, x: x, y: y) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFromDisk() }
        }
    }

    // MARK: - Startup

    func startup() {
        guard !started else { return }
        started = true
        applyAppearance()
        var needsFolderPrompt = false
        if let path = defaultFolder, FileManager.default.fileExists(atPath: path) {
            setRoot(URL(fileURLWithPath: path))
        } else if !UserDefaults.standard.bool(forKey: "askedDefaultFolder") {
            needsFolderPrompt = true
        }
        // Ask about the folder first, then about TeX, so the two dialogs never overlap.
        DispatchQueue.main.async {
            if needsFolderPrompt { self.askDefaultFolder() }
            if !TeX.hasTeX() { self.texSetupVisible = true }
        }
    }

    func askDefaultFolder() {
        UserDefaults.standard.set(true, forKey: "askedDefaultFolder")
        let alert = NSAlert()
        alert.messageText = "Set a default folder for your LaTeX projects?"
        alert.informativeText = "EasyTeX will remember it and open it directly every time you start the app. You can change it later in Settings."
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn, let url = pickFolder() {
            setDefaultFolder(url)
        }
    }

    func setDefaultFolder(_ url: URL) {
        defaultFolder = url.path
        setRoot(url)
    }

    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFolder() {
        if let url = pickFolder() { setRoot(url) }
    }

    func setRoot(_ url: URL) {
        root = url.standardizedFileURL
        rescan()
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    // MARK: - File tree

    private static let hiddenSuffixes = [".aux", ".log", ".out", ".toc", ".synctex.gz", ".bbl", ".blg", ".fls",
                                         ".fdb_latexmk", ".lof", ".lot", ".nav", ".snm", ".vrb", ".run.xml", ".bcf"]

    func rescan() {
        guard let root else { tree = []; return }
        var budget = 4000
        tree = scan(root, depth: 0, budget: &budget)
    }

    private func scan(_ dir: URL, depth: Int, budget: inout Int) -> [FileNode] {
        guard depth < 8, budget > 0 else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var nodes: [FileNode] = []
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = url.lastPathComponent
            if !isDir && AppState.hiddenSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
            budget -= 1
            nodes.append(FileNode(url: url, isDirectory: isDir,
                                  children: isDir ? scan(url, depth: depth + 1, budget: &budget) : nil))
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Opening and tabs

    private static let previewExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "tiff", "heic"]

    func isPreview(_ url: URL) -> Bool { AppState.previewExtensions.contains(url.pathExtension.lowercased()) }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }

        if !openFiles.contains(url) {
            if isPreview(url) {
                openFiles.append(url)
            } else {
                guard let text = readText(url) else { return }
                openFiles.append(url)
                modDates[url] = modDate(url)
                editor.open(path: url.path, text: text)
            }
        } else if !isPreview(url) {
            editor.open(path: url.path, text: "")
        }
        current = url
        if selection != url { selection = url }
    }

    private func readText(_ url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 8_000_000 { showError("“\(url.lastPathComponent)” is too large to edit."); return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            showError("“\(url.lastPathComponent)” is not a UTF-8 text file, so EasyTeX can't edit it safely.")
            return nil
        }
        return text
    }

    func activate(_ url: URL) {
        current = url
        if !isPreview(url) { editor.open(path: url.path, text: "") }
        if selection != url { selection = url }
    }

    func closeCurrentTab() {
        if let current { closeTab(current) } else { NSApp.keyWindow?.performClose(nil) }
    }

    func closeTab(_ url: URL) {
        guard dirty.contains(url) else { discardTabs(under: url); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveAll { self.discardTabs(under: url) }
        case .alertSecondButtonReturn: discardTabs(under: url)
        default: break
        }
    }

    func openExternal(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { setRoot(url); return }
        let file = url.standardizedFileURL
        if let r = root, file.path.hasPrefix(r.path + "/") {
            // already inside the open project
        } else {
            setRoot(file.deletingLastPathComponent())
        }
        open(file)
    }

    // MARK: - Messages from the editor

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            editor.setTheme(dark: dark)
            editor.setOptions(["fontSize": fontSize])
        case "dirty":
            if let path = msg["path"] as? String, let isDirty = msg["dirty"] as? Bool {
                let url = URL(fileURLWithPath: path)
                if isDirty { dirty.insert(url) } else { dirty.remove(url) }
            }
        case "save":
            saveAndCompile()
        case "idle":
            if autoCompile { saveAndCompile() } else if autosave { saveAll() }
        case "cursor":
            if let path = msg["path"] as? String, let line = msg["line"] as? Int, let col = msg["column"] as? Int {
                cursor = (URL(fileURLWithPath: path), line, col)
            }
        default:
            break
        }
    }

    // MARK: - Saving

    func saveAll(then done: @escaping () -> Void = {}) {
        editor.dirtyFiles { [weak self] items in
            guard let self else { done(); return }
            var saved: [String] = []
            for (url, text) in items {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self.dirty.remove(url)
                    self.modDates[url] = self.modDate(url)
                    saved.append(url.path)
                } catch {
                    self.showError("Could not save “\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            self.editor.markSaved(saved)
            done()
        }
    }

    private func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Reload clean buffers that changed on disk (Dropbox, git, another editor) and refresh the tree.
    private func refreshFromDisk() {
        rescan()
        for url in openFiles where !isPreview(url) && !dirty.contains(url) {
            guard let date = modDate(url), date != modDates[url], let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            modDates[url] = date
            editor.reload(path: url.path, text: text)
        }
    }

    // MARK: - Compile

    func saveAndCompile() {
        let now = Date()
        if now.timeIntervalSince(lastSaveTrigger) < 0.3 { return }   // menu + editor may both fire
        lastSaveTrigger = now
        saveAll { [weak self] in self?.startCompile() }
    }

    private func startCompile() {
        if status == .compiling { pendingCompile = true; return }
        guard TeX.hasTeX() else { texSetupVisible = true; return }

        var main: URL?
        if let c = current, !isPreview(c) { main = Compiler.mainFile(for: c, root: root) }
        if main == nil { main = lastMain }
        guard let main else {
            diagnostics = [Diagnostic(kind: .error,
                                      message: "No main file found. Open a .tex file that contains \\documentclass, or add a main.tex.",
                                      file: nil, line: nil)]
            status = .failed
            showProblems = true
            return
        }

        status = .compiling
        Task { [self] in
            let result = await Compiler.compile(main: main)
            lastMain = main
            diagnostics = result.diagnostics
            rawLog = result.log
            status = result.success ? .ok : .failed
            if let url = result.pdf, let doc = PDFDocument(url: url) { pdfDocument = doc }
            applyMarkers()
            if result.diagnostics.contains(where: { $0.kind == .error }) { showProblems = true }
            rescan()
            if !result.success { offerMissingPackages(log: result.log) }
            if pendingCompile { pendingCompile = false; startCompile() }
        }
    }

    private var offeredFiles = Set<String>()

    /// If the log says a package file is missing, ask once and install it with tlmgr, then compile again.
    private func offerMissingPackages(log: String) {
        // PLUS ships the full TeX Live inside the app: there is nothing to download, and the app must not change itself.
        guard !TeX.isBundled else { return }
        let files = MissingPackages.missingFiles(in: log).filter { !offeredFiles.contains($0) }
        guard !files.isEmpty else { return }
        files.forEach { offeredFiles.insert($0) }
        Task { [self] in
            let packages = await MissingPackages.packages(for: files)
            guard !packages.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Install missing LaTeX packages?"
            alert.informativeText = "Your document needs: \(packages.joined(separator: ", ")). EasyTeX can download and install them now."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            status = .compiling
            let result = await MissingPackages.install(packages)
            status = .idle
            if result.ok {
                startCompile()
            } else {
                status = .failed
                showError("The packages could not be installed.\n\n\(result.output.suffix(400))")
            }
        }
    }

    private func applyMarkers() {
        editor.clearMarkers()
        let grouped = Dictionary(grouping: diagnostics.filter { $0.kind == .error && $0.file != nil && $0.line != nil },
                                 by: { $0.file!.standardizedFileURL })
        for (url, items) in grouped where openFiles.contains(url) {
            let payload: [[String: Any]] = items.map { ["line": $0.line ?? 1, "message": $0.message, "error": true] }
            editor.setMarkers(path: url.path, items: payload)
        }
    }

    func reveal(_ diagnostic: Diagnostic) {
        guard let line = diagnostic.line else { return }
        guard let file = diagnostic.file ?? lastMain else { return }
        open(file)
        editor.reveal(path: file.path, line: line, column: 1)
    }

    // MARK: - SyncTeX and PDF

    func jumpToPDF() {
        guard let main = lastMain, let cursor else { return }
        Task { [self] in
            if let loc = await Compiler.syncView(main: main, file: cursor.url, line: cursor.line, column: cursor.column) {
                showPDF = true
                pdf.goTo(page: loc.page, x: loc.x, yFromTop: loc.y)
            }
        }
    }

    private func sourceJump(page: Int, x: Double, y: Double) {
        guard let main = lastMain else { return }
        Task { [self] in
            if let loc = await Compiler.syncEdit(main: main, page: page, x: x, y: y) {
                open(loc.file)
                editor.reveal(path: loc.file.path, line: loc.line, column: 1)
            }
        }
    }

    func exportPDF() {
        guard let main = lastMain, FileManager.default.fileExists(atPath: Compiler.pdfURL(for: main).path) else {
            showError("There is no PDF yet. Press ⌘S to compile first.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = main.deletingPathExtension().lastPathComponent + ".pdf"
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: Compiler.pdfURL(for: main), to: dest) }
            catch { showError("Could not export the PDF: \(error.localizedDescription)") }
        }
    }

    func openPDFInPreview() {
        guard let main = lastMain else { return }
        let url = Compiler.pdfURL(for: main)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    // MARK: - File operations

    private func askName(title: String, message: String = "", initial: String = "", ok: String,
                         completion: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { completion(name) }
        }
    }

    /// Folder that new items go into: the selected folder, the selected file's folder, or the project root.
    func targetFolder() -> URL? {
        if let sel = selection {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir) {
                return isDir.boolValue ? sel : sel.deletingLastPathComponent()
            }
        }
        return root
    }

    func promptNewFile(in folder: URL? = nil) {
        guard let dir = folder ?? targetFolder() else { chooseFolder(); return }
        askName(title: "New File", message: "Name of the new file in “\(dir.lastPathComponent)”:", initial: "main.tex", ok: "Create") { name in
            let file = dir.appendingPathComponent(name.contains(".") ? name : name + ".tex")
            guard !FileManager.default.fileExists(atPath: file.path) else { showError("“\(file.lastPathComponent)” already exists."); return }
            if FileManager.default.createFile(atPath: file.path, contents: Data()) {
                rescan()
                open(file)
            }
        }
    }

    func promptNewFolder(in folder: URL? = nil) {
        guard let dir = folder ?? targetFolder() else { chooseFolder(); return }
        askName(title: "New Folder", message: "Name of the new folder in “\(dir.lastPathComponent)”:", ok: "Create") { name in
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false)
            rescan()
        }
    }

    func newProject(_ template: ProjectTemplate) {
        guard let base = root else { chooseFolder(); return }
        askName(title: "New \(template.rawValue)", message: "Name of the project folder:", initial: "My Project", ok: "Create") { name in
            let dir = base.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: dir.path) else { showError("“\(name)” already exists."); return }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let main = dir.appendingPathComponent("main.tex")
                try template.source.write(to: main, atomically: true, encoding: .utf8)
                rescan()
                open(main)
            } catch {
                showError("Could not create the project: \(error.localizedDescription)")
            }
        }
    }

    func promptRename(_ url: URL) {
        askName(title: "Rename", initial: url.lastPathComponent, ok: "Rename") { name in
            // Write unsaved edits first so nothing is lost when the tab is reopened under the new name.
            saveAll { self.performRename(url, to: name) }
        }
    }

    private func performRename(_ url: URL, to name: String) {
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            showError("Could not rename: \(error.localizedDescription)")
            return
        }
        let renamedCurrentFile = current == url
        discardTabs(under: url)
        rescan()
        if renamedCurrentFile { open(dest) }
    }

    /// Closes, without asking, the tab for `url` and any tabs for files inside it (when it is a folder),
    /// then shows the last remaining tab.
    private func discardTabs(under url: URL) {
        let closing = openFiles.filter { $0 == url || $0.path.hasPrefix(url.path + "/") }
        guard !closing.isEmpty else { return }
        for f in closing {
            dirty.remove(f)
            editor.close(path: f.path)
        }
        openFiles.removeAll { closing.contains($0) }
        if let c = current, closing.contains(c) { current = openFiles.last }
        if let c = current { activate(c) } else { selection = nil }
    }

    func moveToTrash(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            discardTabs(under: url)
            rescan()
        } catch {
            showError("Could not move to the Trash: \(error.localizedDescription)")
        }
    }

    func reveal(inFinder url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func importDropped(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.copyIn(url) }
            }
        }
        return accepted
    }

    private func copyIn(_ source: URL) {
        guard let dir = targetFolder() else { return }
        var dest = dir.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        do { try FileManager.default.copyItem(at: source, to: dest); rescan() }
        catch { showError("Could not import “\(source.lastPathComponent)”: \(error.localizedDescription)") }
    }

    // MARK: - Helpers

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    var windowTitle: String { current?.lastPathComponent ?? "EasyTeX" }
}
