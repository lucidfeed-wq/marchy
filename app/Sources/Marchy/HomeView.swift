import SwiftUI
import AppKit

struct Component: Identifiable {
    let id: String
    let name: String
    let role: String
    let app: String?          // /Applications/<app>.app
    let processName: String?
    var installed: Bool {
        guard let app else { return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") }
        return FileManager.default.fileExists(atPath: "/Applications/\(app).app")
    }
    var running: Bool {
        guard let processName else { return installed }
        return NSWorkspace.shared.runningApplications.contains { $0.localizedName == processName }
    }
}

let components: [Component] = [
    Component(id: "brew", name: "Homebrew", role: "installs everything else", app: nil, processName: nil),
    Component(id: "omniwm", name: "OmniWM", role: "tiling, workspaces and the bar", app: "OmniWM", processName: "OmniWM"),
    Component(id: "karabiner", name: "Karabiner-Elements", role: "Caps Lock as Super", app: "Karabiner-Elements", processName: nil),
    Component(id: "hammerspoon", name: "Hammerspoon", role: "menu, pickers, shortcuts, plugin backends", app: "Hammerspoon", processName: "Hammerspoon"),
    Component(id: "ghostty", name: "Ghostty", role: "terminal", app: "Ghostty", processName: nil),
]

struct HomeView: View {
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var store: Store
    @State private var tick = 0
    @State private var checking = false

    private var hasBrew: Bool { FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                setupCard
                componentsCard
                permissionsCard
                healthCard
            }
            .padding(24)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marchy").font(.largeTitle.bold())
            Text("Omarchy's keyboard-driven desktop on your Mac: Caps Lock as Super, tiling windows, the Omarchy bar, menu, themes and plugins.")
                .foregroundStyle(.secondary)
        }
    }

    private var setupCard: some View {
        Card(title: Paths.isSetUp ? "Your setup" : "Set up this Mac") {
            VStack(alignment: .leading, spacing: 10) {
                if let dev = Paths.developerCheckout {
                    Label("Developer checkout: setup runs from \(dev.path)", systemImage: "hammer")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !hasBrew {
                    Text("Homebrew is needed first. It opens in Terminal and asks for your password.")
                    Button("Install Homebrew…") {
                        TerminalLauncher.run(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                                             title: "installing Homebrew")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text(Paths.isSetUp
                         ? "Update reinstalls the Omarchy layer from this version of Marchy. Your config is backed up first, and edited shortcuts are kept."
                         : "Installs OmniWM, Karabiner-Elements, Hammerspoon, Ghostty and the terminal tools with Homebrew, fetches Omarchy's themes, then installs the Omarchy layer. Your current config is backed up first. macOS asks for your password once (for Karabiner's keyboard driver).")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(Paths.isSetUp ? "Update" : "Set Up") { Task { await runSetup() } }
                            .buttonStyle(.borderedProminent).disabled(runner.running)
                        if Paths.isSetUp {
                            Button("Undo Last Update") { Task { await rollback() } }.disabled(runner.running)
                        }
                    }
                }
            }
        }
    }

    private var componentsCard: some View {
        Card(title: "Components") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(components) { c in
                    HStack {
                        Image(systemName: c.installed ? (c.running ? "checkmark.circle.fill" : "pause.circle") : "circle.dashed")
                            .foregroundStyle(c.installed ? (c.running ? .green : .orange) : .secondary)
                        Text(c.name).frame(width: 160, alignment: .leading)
                        Text(c.role).foregroundStyle(.secondary)
                        Spacer()
                        Text(c.installed ? (c.running ? "running" : "installed") : "not installed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .id("\(c.id)\(tick)")
                }
            }
        }
    }

    private var permissionsCard: some View {
        Card(title: "macOS permissions") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve these once, then log out and back in. Marchy never asks for Full Disk Access or Screen Recording.")
                    .font(.callout).foregroundStyle(.secondary)
                PermissionRow(name: "Accessibility", who: "OmniWM, Hammerspoon",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                PermissionRow(name: "Input Monitoring", who: "OmniWM, Karabiner-Core-Service",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                PermissionRow(name: "Login Items & Extensions", who: "OmniWM, Hammerspoon; Karabiner driver extension",
                              url: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                PermissionRow(name: "Location Services", who: "Hammerspoon (Wi-Fi network names in the bar)",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            }
        }
    }

    private var healthCard: some View {
        Card(title: "Health check") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(checking ? "Checking…" : "Run Health Check") { Task { await check() } }
                        .disabled(checking || !Paths.isSetUp)
                    if let d = store.doctor {
                        Text("\(d.summary["PASS"] ?? 0) passed · \(d.summary["WARN"] ?? 0) warnings · \(d.summary["FAIL"] ?? 0) failed")
                            .foregroundStyle(d.ok ? Color.secondary : Color.red)
                    }
                }
                if let d = store.doctor {
                    ForEach(d.results.filter { $0.status == "FAIL" || $0.status == "WARN" }) { r in
                        HStack(alignment: .top) {
                            Image(systemName: r.status == "FAIL" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.status == "FAIL" ? .red : .orange)
                            VStack(alignment: .leading) {
                                Text(r.check).font(.callout.weight(.medium))
                                Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: actions

    private func runSetup() async {
        let script: String
        if let dev = Paths.developerCheckout {
            script = "cd \(TerminalLauncher.quote(dev.path)) && ./bootstrap.sh"
        } else {
            guard let payload = Paths.bundledPayload else { return }
            let dst = Paths.installedPayload.path
            script = "/bin/mkdir -p \(TerminalLauncher.quote(dst)) && /usr/bin/rsync -a --delete \(TerminalLauncher.quote(payload.path + "/")) \(TerminalLauncher.quote(dst + "/")) && cd \(TerminalLauncher.quote(dst)) && ./bootstrap.sh"
        }
        await runner.stream(Paths.isSetUp ? "Updating" : "Setting up", "/bin/zsh", ["-c", script])
        await store.refreshAll()
    }

    private func rollback() async {
        await runner.stream("Undoing last update", "/bin/zsh", [Paths.activeBuild.appendingPathComponent("rollback.sh").path])
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let r = await Runner.capture(Paths.tool("omarchy-doctor").path, ["--static", "--json", "--no-hs-diag"], timeout: 180)
        store.doctor = try? JSONDecoder().decode(DoctorReport.self, from: Data(r.out.utf8))
    }
}

struct PermissionRow: View {
    let name: String
    let who: String
    let url: String
    var body: some View {
        HStack {
            Text(name).frame(width: 190, alignment: .leading)
            Text(who).foregroundStyle(.secondary)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}
