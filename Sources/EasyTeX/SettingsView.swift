import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Projects") {
                LabeledContent("Default folder") {
                    HStack {
                        Text(state.defaultFolder ?? "None")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            if let url = state.pickFolder() { state.setDefaultFolder(url) }
                        }
                        if state.defaultFolder != nil {
                            Button("Clear") { state.defaultFolder = nil }
                        }
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $state.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Stepper("Editor font size: \(state.fontSize) pt", value: $state.fontSize, in: 9...28)
            }
            Section("Saving and compiling") {
                Toggle("Autosave when you pause typing", isOn: $state.autosave)
                Toggle("Compile automatically when you pause typing", isOn: $state.autoCompile)
                Text("⌘S always saves and compiles. Automatic compiling uses more battery, so it is off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
