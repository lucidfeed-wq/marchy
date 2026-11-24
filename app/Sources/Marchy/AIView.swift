import SwiftUI
import AppKit
import Network
import CryptoKit

/// Choose and connect the AI that converts plugins. Three ways: a local agent CLI the person is
/// signed in to (their Claude / ChatGPT / Grok account), a linked OpenRouter account, or an API
/// key (stored in the macOS Keychain). Ollama runs models on the Mac with no account at all.
struct AIView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var runner: Runner
    @State private var selected: String?

    private func group(_ kind: String) -> [ProviderInfo] { store.providers.filter { $0.kind == kind } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                Section("Use your account (local CLI)") { ForEach(group("cli")) { ProviderRow(p: $0).tag($0.id) } }
                Section("API key or linked account") { ForEach(group("api")) { ProviderRow(p: $0).tag($0.id) } }
                Section("On this Mac") { ForEach(group("local")) { ProviderRow(p: $0).tag($0.id) } }
            }
            .frame(width: 300)
            Divider()
            Group {
                if !Paths.isSetUp {
                    NeedsSetup()
                } else if let id = selected ?? store.providerConfig.provider, let p = store.providers.first(where: { $0.id == id }) {
                    ProviderDetail(p: p).id(p.id)
                } else {
                    ContentUnavailableView("Connect an AI", systemImage: "sparkles",
                                           description: Text("Marchy uses an AI to turn Omarchy's Linux plugins into Mac versions. Pick one on the left. It runs on your own account or key; Marchy has no account of its own and sends nothing anywhere else."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await store.refreshProviders(quick: false) }
    }
}

struct ProviderRow: View {
    @EnvironmentObject var store: Store
    let p: ProviderInfo
    var body: some View {
        HStack {
            Image(systemName: p.ready == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(p.ready == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                Text(p.detail ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if store.providerConfig.provider == p.id { Badge(text: "in use", color: .accentColor) }
        }
    }
}

struct ProviderDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var runner: Runner
    let p: ProviderInfo
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var models: [String] = []
    @State private var message: String?
    @State private var busy = false
    @StateObject private var openRouter = OpenRouterAuth()

    private var isCurrent: Bool { store.providerConfig.provider == p.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(p.name).font(.title2.bold())
                Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                switch p.kind {
                case "cli": cliSection
                case "local": localSection
                default: apiSection
                }

                modelSection

                HStack {
                    Button(isCurrent ? "In Use" : "Use for Converting") { Task { await use() } }
                        .buttonStyle(.borderedProminent).disabled(isCurrent && model == (store.providerConfig.model ?? ""))
                    Button("Test Connection") { Task { await test() } }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
            }
            .padding(24)
        }
        .onAppear {
            model = isCurrent ? (store.providerConfig.model ?? p.default_model ?? "") : (p.default_model ?? "")
            baseURL = isCurrent ? (store.providerConfig.base_url ?? p.base_url ?? "") : (p.base_url ?? "")
        }
    }

    private var explanation: String {
        switch p.id {
        case "claude-code": "Uses the Claude Code app on this Mac and the Claude account you're signed in to. Conversions count toward your Claude plan."
        case "codex": "Uses OpenAI's Codex CLI and the ChatGPT account you're signed in to. Conversions count toward your ChatGPT plan."
        case "grok": "Uses xAI's Grok CLI and the account you're signed in to."
        case "openrouter": "One account for hundreds of models (Claude, GPT, Grok, Gemini, Llama…). Sign in and Marchy receives a key for your account, or paste one."
        case "ollama": "Runs open models entirely on this Mac. Free and private, but needs a large model (30B+) for good ports."
        case "custom": "Any server that speaks the OpenAI chat API (LM Studio, vLLM, a company gateway)."
        default: "Pay-as-you-go with your own API key. The key is stored in your macOS Keychain and only sent to the provider."
        }
    }

    @ViewBuilder private var cliSection: some View {
        Card(title: "Sign-in") {
            VStack(alignment: .leading, spacing: 8) {
                if p.available != true {
                    Text("Not installed on this Mac.").foregroundStyle(.secondary)
                    Button("How to install") { NSWorkspace.shared.open(installURL) }
                } else {
                    Label(p.detail ?? "", systemImage: p.ready == true ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(p.ready == true ? .green : .orange)
                    HStack {
                        Button(p.ready == true ? "Sign In Again…" : "Sign In…") {
                            if let cmd = p.login_cmd {
                                TerminalLauncher.run(cmd.map(TerminalLauncher.quote).joined(separator: " "), title: "sign in to \(p.name)")
                            }
                        }
                        Button("Refresh") { Task { await store.refreshProviders(quick: false) } }
                    }
                    Text("Sign-in opens in Terminal; when it says you're signed in, come back and press Refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var apiSection: some View {
        if p.id == "openrouter" {
            Card(title: "Link your OpenRouter account") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Sign in with OpenRouter…") {
                        openRouter.start { result in
                            Task { @MainActor in
                                switch result {
                                case .success(let k): await saveKey(k, quiet: false)
                                case .failure(let e): message = e.localizedDescription
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if openRouter.waiting { Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        if p.id == "custom" {
            Card(title: "Server") {
                TextField("https://host/v1", text: $baseURL).textFieldStyle(.roundedBorder)
            }
        }
        Card(title: p.has_key == true ? "API key (saved in Keychain)" : "API key") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SecureField(p.has_key == true ? "•••••••• (paste a new key to replace it)" : "Paste your API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await saveKey(key, quiet: false) } }.disabled(key.isEmpty)
                    if p.has_key == true {
                        Button("Remove") {
                            Task {
                                _ = await Runner.capture(Paths.tool("omarchy-port").path, ["provider", "key", p.id, "--clear"])
                                await store.refreshProviders(quick: true)
                            }
                        }
                    }
                }
                if let u = p.keys_url, let url = URL(string: u) {
                    Link("Get a key at \(url.host ?? u)", destination: url).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var localSection: some View {
        Card(title: "Ollama") {
            VStack(alignment: .leading, spacing: 8) {
                Label(p.detail ?? "", systemImage: p.ready == true ? "checkmark.seal.fill" : "xmark.circle")
                    .foregroundStyle(p.ready == true ? .green : .orange)
                HStack {
                    Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                    Button("Refresh") { Task { await store.refreshProviders(quick: false) } }
                }
            }
        }
    }

    @ViewBuilder private var modelSection: some View {
        Card(title: "Model") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(p.kind == "cli" ? "default (the CLI's own choice)" : "model id", text: $model)
                        .textFieldStyle(.roundedBorder)
                    if p.kind != "cli" {
                        Button("Load Models") { Task { await loadModels() } }.disabled(p.ready != true || busy)
                    }
                }
                if !models.isEmpty {
                    Picker("Available", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Text(p.id == "anthropic" ? "Default: claude-opus-5-5." : "Use a strong coding model; small models produce ports that fail the checks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var installURL: URL {
        switch p.id {
        case "claude-code": URL(string: "https://claude.com/claude-code")!
        case "codex": URL(string: "https://developers.openai.com/codex/cli")!
        default: URL(string: "https://x.ai/cli")!
        }
    }

    // MARK: actions

    private func saveKey(_ k: String, quiet: Bool) async {
        let r = await Runner.capture(Paths.tool("omarchy-port").path, ["provider", "key", p.id], stdin: k.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        key = ""
        message = r.status == 0 ? "Key saved in your Keychain." : (r.err.isEmpty ? r.out : r.err)
        await store.refreshProviders(quick: true)
    }

    private func use() async {
        var args = ["provider", "set", p.id]
        if !model.isEmpty { args += ["--model", model] }
        if !baseURL.isEmpty, p.kind != "cli" { args += ["--base-url", baseURL] }
        let r = await Runner.capture(Paths.tool("omarchy-port").path, args)
        message = (r.status == 0 ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        await store.refreshProviders(quick: true)
    }

    private func test() async {
        busy = true
        defer { busy = false }
        let r = await Runner.capture(Paths.tool("omarchy-port").path, ["provider", "test", p.id], timeout: 150)
        message = r.status == 0 ? "✓ Connected. \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))" : "✗ " + ToolError(message: r.err.isEmpty ? r.out : r.err).localizedDescription
    }

    private func loadModels() async {
        busy = true
        defer { busy = false }
        switch await Runner.json(ModelsResponse.self, "omarchy-port", ["provider", "models", p.id], timeout: 90) {
        case .success(let r): models = r.models
        case .failure(let e): message = e.localizedDescription
        }
    }
}

/// OpenRouter OAuth PKCE: the browser redirects to a one-shot listener on 127.0.0.1, and the code is
/// exchanged for a key that belongs to the user's own OpenRouter account.
@MainActor
final class OpenRouterAuth: ObservableObject {
    @Published var waiting = false
    private var listener: NWListener?
    private var verifier = ""
    private var state = ""
    private var completion: ((Result<String, Error>) -> Void)?

    func start(_ done: @escaping (Result<String, Error>) -> Void) {
        stop()
        completion = done
        verifier = Self.random(48)
        state = Self.random(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.handle(c) } }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    guard let self, case .ready = st, let port = l.port?.rawValue else { return }
                    var u = URLComponents(string: "https://openrouter.ai/auth")!
                    u.queryItems = [
                        .init(name: "callback_url", value: "http://localhost:\(port)/callback"),
                        .init(name: "code_challenge", value: challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: self.state),
                        .init(name: "key_label", value: "Marchy"),
                    ]
                    NSWorkspace.shared.open(u.url!)
                }
            }
            listener = l
            waiting = true
            l.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.stop() }
        } catch {
            done(.failure(error))
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let req = String(decoding: data ?? Data(), as: UTF8.self)
                let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let st = items.first { $0.name == "state" }?.value
                let ok = code != nil && st == self.state
                let page = ok ? "Marchy is connected to OpenRouter. You can close this tab." : "Sign-in did not complete. Go back to Marchy and try again."
                let body = "<html><body style='font:16px -apple-system;padding:48px'>\(page)</body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
                guard path.hasPrefix("/callback") else { return }
                self.stop()
                guard ok, let code else {
                    self.completion?(.failure(ToolError(message: "OpenRouter sign-in was cancelled or did not match.")))
                    return
                }
                await self.exchange(code)
            }
        }
    }

    private func exchange(_ code: String) async {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let key = obj["key"] as? String else {
                completion?(.failure(ToolError(message: "OpenRouter did not return a key (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).")))
                return
            }
            completion?(.success(key))
        } catch {
            completion?(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        waiting = false
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
