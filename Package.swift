// swift-tools-version: 6.2
import PackageDescription

// ClaudeBar — menu bar app macOS 26+ (solo Claude).
// SPM puro, zero dipendenze esterne. Tre target:
//   - ClaudeBarCore  : libreria pura (NO AppKit/SwiftUI) — modelli, limiti, parser, pricing, pace.
//   - ClaudeBarApp   : eseguibile @main (AppKit + SwiftUI) — status item, icona, pannello, watcher.
//   - ClaudeBarCLI   : eseguibile dev-tool interno — dump aggregati per validare il parser.
// Build: `swift build`. Bundle .app: `Scripts/bundle.sh`.

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ClaudeBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "ClaudeBarCore", targets: ["ClaudeBarCore"]),
        .executable(name: "ClaudeBarApp", targets: ["ClaudeBarApp"]),
        .executable(name: "ClaudeBarCLI", targets: ["ClaudeBarCLI"]),
    ],
    targets: [
        // MARK: Core (data layer, no UI)
        .target(
            name: "ClaudeBarCore",
            path: "Sources/ClaudeBarCore",
            swiftSettings: strictConcurrency),

        // MARK: App (menu bar app, @main)
        .executableTarget(
            name: "ClaudeBarApp",
            dependencies: ["ClaudeBarCore"],
            path: "Sources/ClaudeBarApp",
            swiftSettings: strictConcurrency),

        // MARK: CLI (dev-only validation tool, NOT shipped in the .app)
        .executableTarget(
            name: "ClaudeBarCLI",
            dependencies: ["ClaudeBarCore"],
            path: "Sources/ClaudeBarCLI",
            swiftSettings: strictConcurrency),

        // MARK: Tests
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"],
            path: "Tests/ClaudeBarCoreTests",
            swiftSettings: strictConcurrency),
        .testTarget(
            name: "ClaudeBarAppTests",
            dependencies: ["ClaudeBarApp", "ClaudeBarCore"],
            path: "Tests/ClaudeBarAppTests",
            swiftSettings: strictConcurrency),
    ])
