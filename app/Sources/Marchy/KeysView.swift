import SwiftUI
import AppKit

/// Shows every shortcut (generated KEYBINDINGS.md) and lets the user edit bindings.toml and apply it.
struct KeysView: View {
    @EnvironmentObject var runner: Runner
    @State private var text = ""
    @State private var filter = ""

    private var bindingsFile: URL { Paths.config.appendingPathComponent("bindings.toml") }
    private var listFile: URL { Paths.config.appendingPathComponent("KEYBINDINGS.md") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortcuts").font(.title2.bold())
                Spacer()
                Button("Edit bindings.toml") { NSWorkspace.shared.open(bindingsFile) }
                Button("Apply Changes") {
                    Task {
                        await runner.stream("Applying shortcuts", Paths.tool("omarchy-keys").path, ["install"])
                        load()
                    }
                }
                .buttonStyle(.borderedProminent).disabled(runner.running || !Paths.isSetUp)
            }
            Text("Hold Caps Lock for Super (tap it for Escape). Every shortcut comes from one file, bindings.toml; edit it, then Apply. Super+K shows this list anywhere.")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            ScrollView {
                Text(filtered).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .onAppear(perform: load)
    }

    private var filtered: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    private func load() {
        text = (try? String(contentsOf: listFile, encoding: .utf8)) ?? "Set up Marchy first (Home screen)."
    }
}
