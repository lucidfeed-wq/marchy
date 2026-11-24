import SwiftUI
import AppKit

@main
struct MarchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var runner = Runner.shared
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("Marchy", id: "main") {
            RootView()
                .environmentObject(runner)
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.check(interactive: true) } }
            }
        }

        MenuBarExtra("Marchy", systemImage: "square.grid.2x2") {
            MenuBarContent()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Updater.check(interactive: false) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", plugins = "Plugins", ai = "AI", themes = "Themes", keys = "Shortcuts"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .plugins: "puzzlepiece.extension"
        case .ai: "sparkles"
        case .themes: "paintpalette"
        case .keys: "command"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    @State private var section: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                Text("Marchy \(Updater.currentVersion) · unofficial, not affiliated with Omarchy or Basecamp")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch section ?? .home {
                    case .home: HomeView()
                    case .plugins: PluginsView()
                    case .ai: AIView()
                    case .themes: ThemesView()
                    case .keys: KeysView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if runner.running || !runner.lines.isEmpty { LogPanel() }
            }
        }
        .task { await store.refreshAll() }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Marchy") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if !store.themes.isEmpty {
            Menu("Theme") {
                ForEach(store.themes) { t in
                    Button((t.current ? "✓ " : "") + t.title) { Task { await store.applyTheme(t) } }
                }
            }
        }
        Button("Reload Desktop") {
            NSWorkspace.shared.open(URL(string: "hammerspoon://omarchy?a=reload")!)
        }
        Button("Keyboard Shortcuts") {
            NSWorkspace.shared.open(Paths.config.appendingPathComponent("KEYBINDINGS.md"))
        }
        Divider()
        Button("Quit Marchy") { NSApp.terminate(nil) }
    }
}

/// Streams the current command's output under every screen.
struct LogPanel: View {
    @EnvironmentObject var runner: Runner
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                if runner.running { ProgressView().controlSize(.small) }
                Text(runner.running ? runner.title : "\(runner.title): \(runner.lastExit == 0 ? "finished" : "failed")")
                    .font(.callout.weight(.medium))
                Spacer()
                if runner.running { Button("Stop") { runner.cancel() } }
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                if !runner.running { Button("Clear") { runner.lines = [] } }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(runner.lines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    .frame(height: 190)
                    .onChange(of: runner.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .background(.bar)
    }
}

/// Shared state loaded from the tools.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var themes: [Theme] = []
    @Published var bundled: [BundledPort] = []
    @Published var portState: [String: PortStatus] = [:]
    @Published var providers: [ProviderInfo] = []
    @Published var providerConfig = ProviderConfig()
    @Published var doctor: DoctorReport?
    @Published var error: String?

    func refreshAll() async {
        guard Paths.isSetUp else { return }
        async let t: () = refreshThemes()
        async let b: () = refreshPorts()
        async let p: () = refreshProviders(quick: true)
        _ = await (t, b, p)
        await refreshProviders(quick: false)
    }

    func refreshThemes() async {
        if case .success(let v) = await Runner.json([Theme].self, "omarchy-theme", ["list", "--json"]) { themes = v }
    }

    func refreshPorts() async {
        if case .success(let v) = await Runner.json([BundledPort].self, "omarchy-port", ["bundled", "--json"]) { bundled = v }
        if case .success(let v) = await Runner.json([String: PortStatus].self, "omarchy-port", ["status", "--json"]) { portState = v }
    }

    func refreshProviders(quick: Bool) async {
        let args = ["providers", "--json"] + (quick ? ["--quick"] : [])
        switch await Runner.json(ProvidersResponse.self, "omarchy-port", args, timeout: 90) {
        case .success(let v):
            providers = v.providers
            providerConfig = v.current
        case .failure(let e): error = e.localizedDescription
        }
    }

    func applyTheme(_ t: Theme) async {
        await Runner.shared.stream("Theme: \(t.title)", Paths.tool("omarchy-theme").path, ["set", t.name])
        await refreshThemes()
    }

    var currentProvider: ProviderInfo? { providers.first { $0.id == providerConfig.provider } }
}
