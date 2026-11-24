import Foundation
import AppKit

/// Where things live. The app ships the whole omarchy-mac build in Contents/Resources/payload;
/// setup copies it to Application Support and runs bootstrap.sh from there. A developer checkout
/// (~/.config/omarchy-mac/build -> a git repo) is used as-is instead.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let config = home.appendingPathComponent(".config/omarchy-mac")
    static let bin = config.appendingPathComponent("bin")
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Marchy")
    static let installedPayload = support.appendingPathComponent("payload")
    static var bundledPayload: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("payload", isDirectory: true)
    }
    static let buildLink = config.appendingPathComponent("build")

    /// A git checkout the user develops in, if ~/.config/omarchy-mac/build points at one.
    static var developerCheckout: URL? {
        let target = buildLink.resolvingSymlinksInPath()
        let git = target.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path) ? target : nil
    }

    /// The build that setup runs from and that bundled ports come from.
    static var activeBuild: URL {
        developerCheckout ?? installedPayload
    }

    static func tool(_ name: String) -> URL { bin.appendingPathComponent(name) }
    static var isSetUp: Bool { FileManager.default.isExecutableFile(atPath: tool("omarchy-port").path) }
}

/// Runs the build's command-line tools. Output streams line by line into a log the UI shows.
@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()

    @Published var lines: [String] = []
    @Published var running = false
    @Published var title = ""
    @Published var lastExit: Int32 = 0
    private var process: Process?

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let h = Paths.home.path
        env["HOME"] = h
        env["PATH"] = ["\(h)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(h)/.grok/bin"].joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["OMARCHY_PORTS_SRC"] = Paths.activeBuild.appendingPathComponent("ports").path
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        if let askpass = Bundle.main.url(forResource: "askpass", withExtension: "sh") {
            env["SUDO_ASKPASS"] = askpass.path   // Homebrew uses `sudo -A`: a native password dialog
        }
        return env
    }

    /// Run a command and stream its output into `lines`. Returns the exit status.
    @discardableResult
    func stream(_ title: String, _ exe: String, _ args: [String], stdin: String? = nil) async -> Int32 {
        if running { return -1 }
        self.title = title
        lines = ["$ \(([URL(fileURLWithPath: exe).lastPathComponent] + args).joined(separator: " "))"]
        running = true
        defer { running = false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = Self.environment
        p.currentDirectoryURL = Paths.home
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let inPipe = Pipe()
        p.standardInput = inPipe
        process = p
        let handle = pipe.fileHandleForReading
        let splitter = LineSplitter()
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            let lines = splitter.feed(chunk)
            if !lines.isEmpty { Task { @MainActor in lines.forEach { self?.append($0) } } }
        }
        do {
            try p.run()
        } catch {
            append("could not start \(exe): \(error.localizedDescription)")
            lastExit = -1
            return -1
        }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        }
        handle.readabilityHandler = nil
        let rest = handle.readDataToEndOfFile()
        let tail = splitter.feed(rest) + splitter.flush()
        await Task.yield()
        tail.forEach { append($0) }
        append(status == 0 ? "✓ done" : "✗ exited with status \(status)")
        lastExit = status
        process = nil
        return status
    }

    func cancel() { process?.terminate() }

    private func append(_ line: String) {
        // strip ANSI colour codes from zsh/brew output
        let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        lines.append(clean)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }

    /// Run quietly and return stdout (for JSON queries). Never blocks the main thread.
    nonisolated static func capture(_ exe: String, _ args: [String], stdin: String? = nil,
                                    timeout: TimeInterval = 120) async -> (status: Int32, out: String, err: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = environment
                p.currentDirectoryURL = Paths.home
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", error.localizedDescription)); return
                }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // read before waiting so large outputs cannot fill the pipe and stall the child
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self),
                                        String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// Decode a tool's JSON output.
    nonisolated static func json<T: Decodable>(_ type: T.Type, _ tool: String, _ args: [String],
                                               timeout: TimeInterval = 120) async -> Result<T, Error> {
        let r = await capture(Paths.tool(tool).path, args, timeout: timeout)
        guard r.status == 0 else {
            return .failure(ToolError(message: r.err.isEmpty ? r.out : r.err))
        }
        do { return .success(try JSONDecoder().decode(T.self, from: Data(r.out.utf8))) }
        catch { return .failure(ToolError(message: "unexpected output from \(tool): \(error)")) }
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message.replacingOccurrences(of: "omarchy-port: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Opens Terminal with a command (sign-in flows and the Homebrew installer need a real terminal).
enum TerminalLauncher {
    static func run(_ command: String, title: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("marchy-\(UUID().uuidString).command")
        let body = "#!/bin/zsh\nclear\nprint -P '%F{blue}Marchy:%f \(title)'\n\(command)\nprint\nprint 'You can close this window and go back to Marchy.'\nrm -f -- \"$0\"\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Splits a byte stream into lines; called from the pipe's background queue.
final class LineSplitter: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var out: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            out.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return out
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let s = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return [s]
    }
}
