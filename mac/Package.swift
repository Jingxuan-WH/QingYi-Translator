// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QingYiTranslator",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Reads and writes the zip container of .docx/.pptx/.xlsx for file translation (MIT license).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Everything that has no user interface: providers, prompts, the streaming client, glossary,
        // incremental translation, history, settings, the update check and file translation. Covered by the tests.
        .target(name: "QingYiCore", dependencies: ["ZIPFoundation"], path: "Sources/QingYiCore"),
        // The macOS app: AppKit shell, SwiftUI views and the platform layer (hotkeys, clipboard, menu bar).
        .executableTarget(
            name: "QingYiTranslator",
            dependencies: ["QingYiCore"],
            path: "Sources/QingYiTranslator"),
        .testTarget(name: "QingYiCoreTests", dependencies: ["QingYiCore", "ZIPFoundation"], path: "Tests/QingYiCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
