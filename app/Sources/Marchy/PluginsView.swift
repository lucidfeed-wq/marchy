import SwiftUI
import AppKit

struct PluginSpec: Codable, Identifiable, Hashable {
    let id: String
    let short: String
    let name: String
    let kinds: [String]
    let source: String
    let trust: String
    let verdict: String
    let why: String
}

enum PluginTab: String, CaseIterable, Identifiable {
    case included = "Included", market = "Marketplace", github = "From GitHub", mine = "Converted"
    var id: String { rawValue }
}

struct PluginsView: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    @State private var tab: PluginTab = .included

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plugins").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(PluginTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 420)
            }
            .padding([.horizontal, .top], 24).padding(.bottom, 12)
            if !Paths.isSetUp {
                NeedsSetup()
            } else {
                switch tab {
                case .included: IncludedPorts()
                case .market: MarketplaceSearch(onConverted: { tab = .mine })
                case .github: GitHubAdd(onAdded: { tab = .mine })
                case .mine: ConvertedPorts()
                }
            }
        }
    }
}

struct NeedsSetup: View {
    var body: some View {
        ContentUnavailableView("Set up Marchy first", systemImage: "wrench.and.screwdriver",
                               description: Text("Plugins install into the desktop layer. Run Set Up on the Home screen."))
    }
}

/// Ports that ship with Marchy (validated before each release).
struct IncludedPorts: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            Section {
                ForEach(store.bundled) { p in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.id.capitalized).font(.body.weight(.medium))
                            Text(p.title).font(.caption).foregroundStyle(.secondary)
                            if !p.requires.isEmpty {
                                Text("Needs: " + p.requires.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if p.status == "partial" { Badge(text: "partial", color: .orange) }
                        if let bar = p.bar, bar != "none" { Badge(text: "bar", color: .blue) }
                        Button(p.installed ? "Remove" : "Install") {
                            Task {
                                let args = p.installed ? ["uninstall", p.id] : ["install", p.id, "--bar"]
                                await runner.stream("\(p.installed ? "Removing" : "Installing") \(p.id)", Paths.tool("omarchy-port").path, args)
                                await store.refreshPorts()
                            }
                        }
                        .disabled(runner.running)
                    }
                    .padding(.vertical, 3)
                }
            } footer: {
                Text("These are Omarchy's own plugins, converted and checked before release. \"Partial\" means macOS can't do everything the Linux version does; each plugin's PORT.md lists the gaps.")
            }
        }
        .task { await store.refreshPorts() }
    }
}

struct MarketplaceSearch: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    var onConverted: () -> Void
    @State private var query = ""
    @State private var results: [MarketEntry] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var confirm: MarketEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search 6,900+ Omarchy plugins (weather, cpu, spotify…)", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(loading)
            }
            .padding(.horizontal, 24)
            ProviderBanner().padding(.horizontal, 24)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 24) }
            List(results) { e in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name == e.id ? e.id.components(separatedBy: ".").last ?? e.id : e.name).font(.body.weight(.medium))
                        if !e.description.isEmpty { Text(e.description).font(.callout).lineLimit(2) }
                        Text("\(e.id) · \(e.repoShort)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !e.category.isEmpty { Badge(text: e.category, color: .gray) }
                    if e.flagged {
                        Badge(text: e.security + (e.caps.isEmpty ? "" : ": " + e.caps.joined(separator: ", ")), color: .orange)
                            .help("The marketplace's automated security review flagged this plugin. Marchy only reads its code, but review the port before installing.")
                    }
                    Button("Convert") { confirm = e }.disabled(runner.running || store.currentProvider?.ready != true)
                }
                .padding(.vertical, 3)
            }
            if total > results.count {
                Text("Showing \(results.count) of \(total). Refine the search to see more.").font(.caption)
                    .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
        .task { if results.isEmpty { await search() } }
        .alert(item: $confirm) { e in
            Alert(title: Text("Convert \(e.id)?"),
                  message: Text("Marchy downloads \(e.repoShort) at the commit the marketplace validated, and your AI provider (\(store.currentProvider?.name ?? "none")) writes a Mac version. The plugin's code is only read, never run. You review the checks before installing."),
                  primaryButton: .default(Text("Convert")) { Task { await convert(e) } },
                  secondaryButton: .cancel())
        }
    }

    private func search() async {
        loading = true
        defer { loading = false }
        let words = query.split(separator: " ").map(String.init)
        switch await Runner.json(MarketResponse.self, "omarchy-port", ["market", "--json", "--limit", "80"] + words, timeout: 180) {
        case .success(let r):
            results = r.results; total = r.total; error = nil
        case .failure(let e): error = e.localizedDescription
        }
    }

    private func convert(_ e: MarketEntry) async {
        let id = portID(for: e.id)
        let op = TerminalLauncher.quote(Paths.tool("omarchy-port").path)
        let script = "\(op) sync && \(op) add \(TerminalLauncher.quote(e.id)) && \(op) analyze >/dev/null && \(op) generate \(id) && \(op) validate \(id)"
        await runner.stream("Converting \(e.id)", "/bin/zsh", ["-c", script])
        await store.refreshPorts()
        onConverted()
    }
}

struct GitHubAdd: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    var onAdded: () -> Void
    @State private var repo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Any GitHub repository with an Omarchy plugin (a manifest.json with an \"id\"). Use owner/repo, a GitHub URL, or a /tree/<branch>/<folder> link.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("owner/repo or https://github.com/owner/repo", text: $repo).textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task {
                        let op = TerminalLauncher.quote(Paths.tool("omarchy-port").path)
                        await runner.stream("Adding \(repo)", "/bin/zsh",
                                            ["-c", "\(op) sync && \(op) add \(TerminalLauncher.quote(repo)) && \(op) analyze >/dev/null"])
                        if runner.lastExit == 0 { onAdded() }
                    }
                }
                .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty || runner.running)
            }
            Text("Code from GitHub is only read by the converter and treated as untrusted data. It never runs on your Mac; only the port your AI writes does, after it passes the checks and you install it.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

/// Plugins added from the marketplace or GitHub: convert, check, install.
struct ConvertedPorts: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    @State private var specs: [PluginSpec] = []

    var body: some View {
        VStack(alignment: .leading) {
            ProviderBanner().padding(.horizontal, 24)
            List {
                if specs.isEmpty {
                    Text("Nothing added yet. Find plugins under Marketplace or From GitHub.").foregroundStyle(.secondary)
                }
                ForEach(specs) { s in row(s) }
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func row(_ s: PluginSpec) -> some View {
        let st = store.portState[s.short]
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.body.weight(.medium))
                Text("\(s.id) · from \(s.source)").font(.caption).foregroundStyle(.secondary)
                if let checks = st?.checks {
                    let bad = checks.filter { $0.value.hasPrefix("ERR") || $0.value.hasPrefix("WARN") }
                    ForEach(bad.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        Text("\(k): \(v)").font(.caption2).foregroundStyle(v.hasPrefix("ERR") ? .red : .orange).lineLimit(2)
                    }
                }
            }
            Spacer()
            Badge(text: s.verdict, color: s.verdict == "not-portable" ? .red : (s.verdict == "partial" ? .orange : .green))
            if st?.installed != nil { Badge(text: "installed", color: .blue) }
            else if st?.validated != nil { Badge(text: "checked", color: .green) }
            else if st?.generated != nil { Badge(text: "converted", color: .gray) }
            Menu("Actions") {
                Button("Convert with \(store.currentProvider?.name ?? "AI")") { run("Converting \(s.short)", ["generate", s.short], then: ["validate", s.short]) }
                    .disabled(store.currentProvider?.ready != true)
                Button("Run checks") { run("Checking \(s.short)", ["validate", s.short]) }.disabled(st?.generated == nil)
                Button("Install") { run("Installing \(s.short)", ["install", s.short, "--bar"]) }.disabled(st?.validated == nil)
                Button("Remove from desktop") { run("Removing \(s.short)", ["uninstall", s.short]) }.disabled(st?.installed == nil)
                Divider()
                Button("Show port files") {
                    NSWorkspace.shared.open(Paths.config.appendingPathComponent("port/out/\(s.short)"))
                }
            }
            .frame(width: 100).disabled(runner.running)
        }
        .padding(.vertical, 3)
    }

    private func run(_ title: String, _ args: [String], then: [String]? = nil) {
        Task {
            let op = Paths.tool("omarchy-port").path
            let status = await runner.stream(title, op, args)
            if status == 0, let then { await runner.stream(title, op, then) }
            await store.refreshPorts()
        }
    }

    private func load() async {
        await store.refreshPorts()
        if case .success(let all) = await Runner.json([String: PluginSpec].self, "omarchy-port", ["analyze", "--json"], timeout: 120) {
            specs = all.values.filter { $0.trust == "third-party" }.sorted { $0.name < $1.name }
        }
    }
}

/// Reminds the user which AI writes ports, or that none is connected.
struct ProviderBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let p = store.currentProvider, p.ready == true {
            Label("Ports are written by \(p.name)\(store.providerConfig.model.map { " · \($0)" } ?? "")", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Connect an AI on the AI screen to convert plugins (your Claude, ChatGPT or Grok account, or an API key).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}
