import Foundation

// JSON shapes printed by the build's tools (omarchy-port, omarchy-theme, omarchy-doctor).

struct ProviderConfig: Codable, Equatable {
    var provider: String?
    var model: String?
    var base_url: String?
}

struct ProviderInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String          // cli | api | local
    var keys_url: String?
    var default_model: String?
    var base_url: String?
    var path: String?
    var available: Bool?
    var login_cmd: [String]?
    var ready: Bool?
    var detail: String?
    var has_key: Bool?
}

struct ProvidersResponse: Codable {
    let current: ProviderConfig
    let providers: [ProviderInfo]
}

struct ModelsResponse: Codable { let models: [String] }

struct MarketEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let repo: String
    var commit: String?
    let security: String
    let caps: [String]
    let kind: String
    let category: String
    let tags: [String]
    let description: String
    var manifest: String?

    var repoShort: String { repo.replacingOccurrences(of: "https://github.com/", with: "") }
    var flagged: Bool { !["pass", "passed"].contains(security.lowercased()) }
}

struct MarketResponse: Codable {
    let total: Int
    let results: [MarketEntry]
}

struct BundledPort: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    var status: String?
    var bar: String?
    var requires: [String]
    var installed: Bool
}

struct PortStatus: Codable, Hashable {
    var id: String?
    var verdict: String?
    var why: String?
    var generated: String?
    var validated: String?
    var installed: String?
    var checks: [String: String]?
}

struct Theme: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let title: String
    let current: Bool
    let mode: String
    let accent: String
    let background: String
    let foreground: String
    let preview: String?
}

struct DoctorResult: Codable, Identifiable, Hashable {
    var id: String { check + status }
    let status: String
    let check: String
    let detail: String
}

struct DoctorReport: Codable {
    let mode: String
    let summary: [String: Int]
    let ok: Bool
    let results: [DoctorResult]
}

/// Third-party plugins get an "x-" prefixed port id (mirrors omarchy-port's short()).
func portID(for pluginID: String) -> String {
    if pluginID.hasPrefix("omarchy.") { return String(pluginID.dropFirst("omarchy.".count)) }
    let lowered = pluginID.lowercased()
    let dashed = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    return "x-" + dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
