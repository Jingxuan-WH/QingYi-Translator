import AppKit
import QingYiCore

/// `--snapshot <dir>`: renders every window to PNG files (for the README and for checking the layout
/// without a screen), then quits. Uses a mock translation service when one is configured.
enum Snapshots {
    private static let sampleText = """
    Deep neural networks have achieved remarkable success in speech recognition, image classification and machine translation. However, their performance often degrades when the test data differ from the training data.

    In this work, we propose a lightweight adaptation method that improves robustness without retraining the entire model. Experiments on three benchmarks show consistent gains with less than 1% additional parameters.
    """

    @MainActor
    static func run(app: AppDelegate, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ window: NSWindow?, _ name: String) {
            guard let window, let view = window.contentView else {
                Log.error("快照失败：没有窗口 \(name)")
                return
            }
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            do {
                try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            } catch {
                Log.error("写入快照失败：\(name)", error)
            }
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        await pause(1.5)
        capture(app.mainWindowForSnapshots, "main-empty.png")

        app.model.showWithText(sampleText)
        await pause(4)
        capture(app.mainWindowForSnapshots, "main-translated.png")

        app.model.isHistoryOpen = true
        await pause(0.8)
        capture(app.mainWindowForSnapshots, "main-history.png")
        app.model.isHistoryOpen = false

        app.openSettings()
        await pause(1.2)
        capture(app.settingsWindowForSnapshots, "settings.png")
        app.settingsWindowForSnapshots?.close()
        await pause(0.3)

        app.openGlossary(from: app.mainWindowForSnapshots)
        await pause(1.2)
        capture(app.glossaryWindowForSnapshots, "glossary.png")
        app.glossaryWindowForSnapshots?.close()
        await pause(0.3)

        let release = ReleaseInfo(version: SemanticVersion(9, 9, 9), tag: "v9.9.9", notes: "## 新功能\n- 示例更新说明 **加粗** `代码`\n- [链接](https://example.com)",
                                  pageUrl: UpdateService.releasesPage, downloadUrl: "https://github.com/\(UpdateService.repository)/releases/download/v9.9.9/\(UpdateService.assetName)",
                                  size: 0, sha256: nil, publishedAt: Date())
        app.showUpdateDialog(release, from: app.mainWindowForSnapshots)
        await pause(1.2)
        capture(app.updateWindowForSnapshots, "update.png")
        app.updateWindowForSnapshots?.close()
        await pause(0.3)

        ThemeManager.apply(AppSettings.themeDark)
        await pause(1.2)
        capture(app.mainWindowForSnapshots, "main-dark.png")

        Loc.shared.apply(Loc.englishCode)
        await pause(1)
        capture(app.mainWindowForSnapshots, "main-dark-english.png")

        app.exitApp()
    }
}
