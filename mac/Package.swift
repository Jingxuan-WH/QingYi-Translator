// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QingYiTranslator",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that has no user interface: providers, prompts, the streaming client, glossary,
        // incremental translation, history, settings and the update check. Covered by the tests.
        .target(name: "QingYiCore", path: "Sources/QingYiCore"),
        // The macOS app: AppKit shell, SwiftUI views and the platform layer (hotkeys, clipboard, menu bar).
        .executableTarget(
            name: "QingYiTranslator",
            dependencies: ["QingYiCore"],
            path: "Sources/QingYiTranslator"),
        .testTarget(name: "QingYiCoreTests", dependencies: ["QingYiCore"], path: "Tests/QingYiCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
