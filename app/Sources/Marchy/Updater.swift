import Foundation
import AppKit

/// Checks GitHub Releases for a newer Marchy. Installs are by the user (Homebrew or the DMG), so
/// nothing is downloaded or replaced behind their back.
enum Updater {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "MarchyRepository") as? String ?? "lucidfeed-wq/marchy"
    }

    @MainActor
    static func check(interactive: Bool) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Marchy", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            if interactive { alert("Couldn't check for updates", "GitHub could not be reached.") }
            return
        }
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if newer(latest, than: currentVersion) {
            let a = NSAlert()
            a.messageText = "Marchy \(latest) is available"
            a.informativeText = "You have \(currentVersion). Update with Homebrew (brew upgrade --cask marchy) or download it, then press Update on the Home screen."
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn, let page = obj["html_url"] as? String, let u = URL(string: page) {
                NSWorkspace.shared.open(u)
            }
        } else if interactive {
            alert("Marchy is up to date", "Version \(currentVersion).")
        }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        guard !y.isEmpty else { return false }   // dev builds never nag
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    @MainActor
    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
