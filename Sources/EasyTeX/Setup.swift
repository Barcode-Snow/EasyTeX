import SwiftUI

// MARK: - First-run TeX installation (Lite version)

/// Installs TinyTeX with its official installer script (https://tinytex.yihui.org). It ends up in ~/Library/TinyTeX,
/// which `TeX.binDir()` already searches. The PLUS version ships a TeX distribution inside the app instead.
@MainActor
final class TeXInstaller: ObservableObject {
    enum Phase { case idle, running, done, failed }
    @Published var phase: Phase = .idle
    @Published var message = ""
    @Published var log = ""

    private func append(_ text: String) { log += text.hasSuffix("\n") ? text : text + "\n" }

    func install() {
        guard phase != .running else { return }
        phase = .running
        log = ""
        message = "Downloading the installer…"
        Task { [self] in
            do {
                let url = URL(string: "https://tinytex.yihui.org/install-bin-unix.sh")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "EasyTeX", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The installer could not be downloaded."])
                }
                let script = FileManager.default.temporaryDirectory.appendingPathComponent("easytex-install-tinytex.sh")
                try data.write(to: script)
                append("Downloaded the installer script.")

                message = "Installing TeX. This takes a few minutes…"
                let status = await runInstaller(script)
                if status != 0 { append("The installer exited with status \(status).") }

                if !TeX.hasTeX() {
                    message = "Adding latexmk…"
                    await installLatexmk()
                }
                if TeX.hasTeX() {
                    phase = .done
                    message = "TeX is ready."
                } else {
                    phase = .failed
                    message = "The installation did not finish. See the details below."
                }
            } catch {
                append(error.localizedDescription)
                phase = .failed
                message = error.localizedDescription
            }
        }
    }

    private func runInstaller(_ script: URL) async -> Int32 {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "--no-path"]
            var env = ProcessInfo.processInfo.environment
            env["TINYTEX_INSTALLER"] = "TinyTeX-1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self.append(text) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                Task { @MainActor in self.append("Could not start the installer: \(error.localizedDescription)") }
                cont.resume(returning: -1)
            }
        }
    }

    /// TinyTeX's smaller bundles do not always include latexmk.
    private func installLatexmk() async {
        let tinytex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/TinyTeX/bin")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: tinytex, includingPropertiesForKeys: nil)) ?? []
        guard let bin = dirs.first(where: { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("tlmgr").path) }) else {
            append("tlmgr was not found.")
            return
        }
        let result = await Shell.run(bin.appendingPathComponent("tlmgr"), ["install", "latexmk"], binDir: bin)
        append(result.output)
    }
}

struct TeXSetupSheet: View {
    @EnvironmentObject var state: AppState
    @StateObject private var installer = TeXInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time setup").font(.title2.bold())
                    Text("EasyTeX needs a TeX distribution to turn your documents into PDFs.")
                        .foregroundStyle(.secondary)
                }
            }

            switch installer.phase {
            case .idle:
                Text("EasyTeX will download TinyTeX (a few hundred MB) into your Library folder. This only happens once. If you already have MacTeX installed, EasyTeX finds it automatically.")
                    .font(.callout)
                HStack {
                    Button("Check Again") { if TeX.hasTeX() { state.texSetupVisible = false } }
                    Spacer()
                    Button("Not Now") { state.texSetupVisible = false }
                    Button("Install TeX") { installer.install() }
                        .keyboardShortcut(.defaultAction)
                }
            case .running:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(installer.message)
                }
                details
            case .done:
                Label(installer.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Spacer()
                    Button("Done") { state.texSetupVisible = false }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed:
                Label(installer.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                details
                HStack {
                    Spacer()
                    Button("Close") { state.texSetupVisible = false }
                    Button("Try Again") { installer.install() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var details: some View {
        DisclosureGroup("Details") {
            ScrollView {
                Text(installer.log.isEmpty ? "Waiting for output…" : installer.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Missing packages (asks first, then installs with tlmgr)

enum Shell {
    /// Runs a tool and returns (exit status, combined output). Output is read while the process runs.
    static func run(_ exe: URL, _ args: [String], binDir: URL) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = exe
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = binDir.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            DispatchQueue.global().async {
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    cont.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
}

enum MissingPackages {
    /// Files LaTeX could not find, e.g. "algorithm2e.sty".
    static func missingFiles(in log: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"File `([^']+\.(?:sty|cls|def|cfg|clo|fd))' not found"#) else { return [] }
        let ns = log as NSString
        var found: [String] = []
        for m in regex.matches(in: log, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !found.contains(name) { found.append(name) }
        }
        return found
    }

    /// Maps file names to TeX Live package names with `tlmgr search`.
    static func packages(for files: [String]) async -> [String] {
        guard let bin = TeX.binDir() else { return [] }
        var packages: [String] = []
        for file in files {
            let result = await Shell.run(bin.appendingPathComponent("tlmgr"),
                                         ["search", "--file", "--global", "/" + file], binDir: bin)
            for line in result.output.components(separatedBy: "\n") {
                guard line.hasSuffix(":"), !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("tlmgr") else { continue }
                let name = String(line.dropLast())
                if !name.contains("/"), !name.contains(" "), !packages.contains(name) { packages.append(name); break }
            }
        }
        return packages
    }

    static func install(_ packages: [String]) async -> (ok: Bool, output: String) {
        guard let bin = TeX.binDir() else { return (false, "TeX was not found.") }
        let result = await Shell.run(bin.appendingPathComponent("tlmgr"), ["install"] + packages, binDir: bin)
        return (result.status == 0, result.output)
    }
}
