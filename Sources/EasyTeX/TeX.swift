import Foundation

// MARK: - Locating a TeX installation

enum TeX {
    /// First directory that contains an executable `latexmk`.
    /// Order: inside the app (PLUS) → TinyTeX (installed by Lite) → MacTeX/BasicTeX → TeX Live → Homebrew.
    static func binDir() -> URL? {
        let fm = FileManager.default
        for dir in candidates() where fm.isExecutableFile(atPath: dir.appendingPathComponent("latexmk").path) {
            return dir
        }
        return nil
    }

    static func hasTeX() -> Bool { binDir() != nil }

    /// True when TeX comes from inside the app (EasyTeX PLUS). That copy is complete and read-only,
    /// so EasyTeX never tries to download packages into it.
    static var isBundled: Bool {
        guard let bin = binDir(), let res = Bundle.main.resourceURL else { return false }
        return bin.standardizedFileURL.path.hasPrefix(res.standardizedFileURL.path + "/")
    }

    private static func candidates() -> [URL] {
        var list: [URL] = []
        if let res = Bundle.main.resourceURL {
            list += subdirs(of: res.appendingPathComponent("texlive/bin"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        list += subdirs(of: home.appendingPathComponent("Library/TinyTeX/bin"))
        list.append(URL(fileURLWithPath: "/Library/TeX/texbin"))
        for year in subdirs(of: URL(fileURLWithPath: "/usr/local/texlive")) {
            list += subdirs(of: year.appendingPathComponent("bin"))
        }
        list.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        list.append(URL(fileURLWithPath: "/usr/local/bin"))
        return list
    }

    private static func subdirs(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Compile model

struct Diagnostic: Identifiable, Hashable {
    enum Kind { case error, warning }
    let id = UUID()
    let kind: Kind
    let message: String
    let file: URL?
    let line: Int?
}

struct CompileResult {
    var success: Bool
    var pdf: URL?
    var diagnostics: [Diagnostic]
    var log: String
    var timedOut: Bool
}

enum Engine: String {
    case pdflatex, xelatex, lualatex
    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex: return "-pdfxe"
        case .lualatex: return "-pdflua"
        }
    }
}

// MARK: - Compiler

enum Compiler {
    static let timeout: TimeInterval = 120
    static let buildFolderName = ".build"

    /// Which file should be compiled when `file` was saved?
    /// 1. `% !TEX root = other.tex` magic comment, 2. the file itself if it has \documentclass,
    /// 3. main.tex / any .tex with \documentclass in this or a parent folder (up to `root`).
    static func mainFile(for file: URL, root: URL?) -> URL? {
        let fm = FileManager.default
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        if let rootName = magicComment("root", in: text) {
            let candidate = URL(fileURLWithPath: rootName, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        if text.contains("\\documentclass") { return file }

        var dir = file.deletingLastPathComponent().standardizedFileURL
        let stop = root?.standardizedFileURL.deletingLastPathComponent().path
        var hops = 0
        while dir.path != "/" && dir.path != stop && hops < 6 {
            hops += 1
            let main = dir.appendingPathComponent("main.tex")
            if hasDocumentClass(main) { return main }
            let texFiles = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "tex" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let hit = texFiles.first(where: hasDocumentClass) { return hit }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func hasDocumentClass(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("\\documentclass")
    }

    /// Reads `% !TEX key = value` from the first lines of a file.
    static func magicComment(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
            let s = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard s.hasPrefix("%"), s.contains("!tex") else { continue }
            let original = String(line)
            let parts = original.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let k = parts[0].lowercased()
            if k.contains(key.lowercased()) {
                return parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func engine(for main: URL) -> Engine {
        let text = (try? String(contentsOf: main, encoding: .utf8)) ?? ""
        switch magicComment("program", in: text)?.lowercased() {
        case "xelatex": return .xelatex
        case "lualatex": return .lualatex
        default: return .pdflatex
        }
    }

    static func buildDir(for main: URL) -> URL {
        main.deletingLastPathComponent().appendingPathComponent(buildFolderName, isDirectory: true)
    }

    static func pdfURL(for main: URL) -> URL {
        buildDir(for: main).appendingPathComponent(main.deletingPathExtension().lastPathComponent + ".pdf")
    }

    /// LaTeX cannot create folders: mirror the project's sub-folders inside the build folder (needed for \include).
    private static func mirrorFolders(of dir: URL, into build: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: build, withIntermediateDirectories: true)
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var count = 0
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rel = url.path.dropFirst(dir.path.count + 1)
            try? fm.createDirectory(at: build.appendingPathComponent(String(rel)), withIntermediateDirectories: true)
            count += 1
            if count > 300 { break }
        }
    }

    static func compile(main: URL) async -> CompileResult {
        guard let bin = TeX.binDir() else {
            return CompileResult(success: false, pdf: nil, diagnostics: [
                Diagnostic(kind: .error, message: "No TeX installation found.", file: nil, line: nil)
            ], log: "", timedOut: false)
        }

        let dir = main.deletingLastPathComponent()
        let build = buildDir(for: main)
        mirrorFolders(of: dir, into: build)

        // latexmk remembers earlier runs and will not run again if the sources did not change, even when
        // the last run failed or a different TeX produced it ("gave an error in previous invocation").
        // Forget runs made by another TeX installation, and force a fresh run after a failure.
        let stem = main.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let texMarker = build.appendingPathComponent(stem + ".easytex-tex")
        let failedMarker = build.appendingPathComponent(stem + ".easytex-failed")
        let previousTeX = try? String(contentsOf: texMarker, encoding: .utf8)
        if previousTeX != bin.path {
            for ext in ["fdb_latexmk", "aux", "log", "fls", "bbl", "blg", "toc", "out", "synctex.gz"] {
                try? fm.removeItem(at: build.appendingPathComponent(stem + "." + ext))
            }
            try? bin.path.write(to: texMarker, atomically: true, encoding: .utf8)
        }
        let forceRun = fm.fileExists(atPath: failedMarker.path)

        let outFile = build.appendingPathComponent("latexmk.out")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        let outHandle = try? FileHandle(forWritingTo: outFile)

        let process = Process()
        process.executableURL = bin.appendingPathComponent("latexmk")
        process.currentDirectoryURL = dir
        process.arguments = [engine(for: main).latexmkFlag]
            + (forceRun ? ["-g"] : [])
            + ["-interaction=nonstopmode", "-file-line-error", "-synctex=1",
               "-outdir=\(buildFolderName)", main.lastPathComponent]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = outHandle

        let flag = TimeoutFlag()
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        flag.fired = true
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            } catch {
                flag.launchError = error.localizedDescription
                cont.resume(returning: -1)
            }
        }
        try? outHandle?.close()

        if status == 0 {
            try? fm.removeItem(at: failedMarker)
        } else {
            fm.createFile(atPath: failedMarker.path, contents: nil)
        }

        let logText = (try? String(contentsOf: build.appendingPathComponent(stem + ".log"), encoding: .utf8))
            ?? (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        var diagnostics = parseLog(logText, base: dir)

        if let msg = flag.launchError {
            diagnostics.insert(Diagnostic(kind: .error, message: "Could not start latexmk: \(msg)", file: nil, line: nil), at: 0)
        }
        if flag.fired {
            diagnostics.insert(Diagnostic(kind: .error, message: "Compilation stopped after \(Int(timeout)) seconds.", file: nil, line: nil), at: 0)
        }
        if status != 0 && !diagnostics.contains(where: { $0.kind == .error }) {
            let tail = (try? String(contentsOf: outFile, encoding: .utf8))?
                .split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
            diagnostics.insert(Diagnostic(kind: .error, message: tail.isEmpty ? "latexmk failed (exit \(status))." : tail,
                                          file: nil, line: nil), at: 0)
        }

        let pdf = pdfURL(for: main)
        let havePDF = FileManager.default.fileExists(atPath: pdf.path)
        let fullLog = logText.isEmpty ? ((try? String(contentsOf: outFile, encoding: .utf8)) ?? "") : logText
        return CompileResult(success: status == 0 && havePDF, pdf: havePDF ? pdf : nil,
                             diagnostics: diagnostics, log: fullLog, timedOut: flag.fired)
    }

    // MARK: Log parsing

    static func parseLog(_ log: String, base: URL) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var seen = Set<String>()
        func add(_ d: Diagnostic) {
            let key = "\(d.kind)|\(d.file?.path ?? "")|\(d.line ?? 0)|\(d.message)"
            if seen.insert(key).inserted { out.append(d) }
        }
        let lines = log.components(separatedBy: "\n")

        // file:line: message   (from -file-line-error)
        let errRegex = try? NSRegularExpression(pattern: #"^(\.{0,2}/?[^:\n]+\.(?:tex|sty|cls|bib|ltx)):(\d+): (.*)$"#)
        // "... on input line 12."
        let warnRegex = try? NSRegularExpression(pattern: #"(?:LaTeX|Package [^ ]+|Class [^ ]+) Warning: (.*?)(?: on input line (\d+))?\.?$"#)

        for line in lines {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = errRegex?.firstMatch(in: line, range: full) {
                let path = ns.substring(with: m.range(at: 1))
                let lineNo = Int(ns.substring(with: m.range(at: 2)))
                let msg = ns.substring(with: m.range(at: 3))
                add(Diagnostic(kind: .error, message: msg,
                               file: URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL, line: lineNo))
            } else if let m = warnRegex?.firstMatch(in: line, range: full), line.contains("Warning:") {
                let msg = ns.substring(with: m.range(at: 1))
                var lineNo: Int?
                if m.range(at: 2).location != NSNotFound { lineNo = Int(ns.substring(with: m.range(at: 2))) }
                add(Diagnostic(kind: .warning, message: msg, file: nil, line: lineNo))
            }
        }
        return out
    }

    // MARK: SyncTeX

    struct SourceLocation { let file: URL; let line: Int }
    struct PDFLocation { let page: Int; let x: Double; let y: Double }   // page is 1-based; y measured from the top

    /// PDF click → source position.  (x, y) in PDF points from the top-left of the page.
    static func syncEdit(main: URL, page: Int, x: Double, y: Double) async -> SourceLocation? {
        guard let bin = TeX.binDir() else { return nil }
        let pdf = pdfURL(for: main)
        let output = await run(bin.appendingPathComponent("synctex"),
                               ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"],
                               cwd: buildDir(for: main), bin: bin)
        var input: String?
        var line: Int?
        for l in output.components(separatedBy: "\n") {
            if l.hasPrefix("Input:") && input == nil { input = String(l.dropFirst(6)) }
            if l.hasPrefix("Line:") && line == nil { line = Int(l.dropFirst(5)) }
        }
        guard let input, let line else { return nil }
        let base = main.deletingLastPathComponent()
        let url = input.hasPrefix("/") ? URL(fileURLWithPath: input)
                                       : URL(fileURLWithPath: input, relativeTo: base)
        return SourceLocation(file: url.standardizedFileURL, line: line)
    }

    /// Source position → PDF position.
    static func syncView(main: URL, file: URL, line: Int, column: Int) async -> PDFLocation? {
        guard let bin = TeX.binDir() else { return nil }
        let pdf = pdfURL(for: main)
        let output = await run(bin.appendingPathComponent("synctex"),
                               ["view", "-i", "\(line):\(column):\(file.path)", "-o", pdf.path],
                               cwd: buildDir(for: main), bin: bin)
        var page: Int?, x: Double?, y: Double?
        for l in output.components(separatedBy: "\n") {
            if l.hasPrefix("Page:") && page == nil { page = Int(l.dropFirst(5)) }
            if l.hasPrefix("x:") && x == nil { x = Double(l.dropFirst(2)) }
            if l.hasPrefix("y:") && y == nil { y = Double(l.dropFirst(2)) }
        }
        guard let page, let x, let y else { return nil }
        return PDFLocation(page: page, x: x, y: y)
    }

    /// Small helper: run a tool and return its stdout.
    private static func run(_ exe: URL, _ args: [String], cwd: URL, bin: URL) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = bin.path + ":/usr/bin:/bin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
                // synctex output is tiny, so reading after launch cannot fill the pipe buffer.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    var fired = false
    var launchError: String?
}
