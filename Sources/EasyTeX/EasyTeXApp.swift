import SwiftUI
import AppKit

@main
@MainActor
struct EasyTeXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        Window("EasyTeX", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { url in state.openExternal(url) }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File…") { state.promptNewFile() }
                    .keyboardShortcut("n")
                Button("Open Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save and Compile") { state.saveAndCompile() }
                    .keyboardShortcut("s")
                Button("Close Tab") { state.closeCurrentTab() }
                    .keyboardShortcut("w")
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle File Tree") { state.showTree.toggle() }
                    .keyboardShortcut("b")
                Button("Toggle PDF Preview") { state.showPDF.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Problems and Log") { state.showProblems.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("LaTeX") {
                Button("Compile") { state.saveAndCompile() }
                Button("Jump to PDF Position") { state.jumpToPDF() }
                    .keyboardShortcut("j")
                Divider()
                Button("Export PDF…") { state.exportPDF() }
                Button("Open PDF in Preview") { state.openPDFInPreview() }
            }
        }

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started without an app bundle (swift run / Xcode); harmless otherwise.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard !state.dirty.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Do you want to save your changes?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            state.saveAll { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
