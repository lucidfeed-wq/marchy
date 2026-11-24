// swift-tools-version: 6.0
// Marchy: the Mac app that installs and manages the Omarchy-style desktop (omarchy-mac).
// Build an .app with ../scripts/build-app.sh (works with the Command Line Tools; no Xcode needed).
import PackageDescription

let package = Package(
    name: "Marchy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Marchy",
            path: "Sources/Marchy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
