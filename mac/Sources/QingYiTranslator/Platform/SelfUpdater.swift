import AppKit
import QingYiCore

/// Replaces the running .app bundle with a downloaded version. The old bundle is renamed, the new one takes its
/// place, and the new copy is started; it waits for this process to exit before taking over.
enum SelfUpdater {
    private static var bundleURL: URL { Bundle.main.bundleURL }

    static var downloadPath: URL { AppPaths.dataDirectory.appendingPathComponent("update/\(UpdateService.assetName)") }

    private static var backupURL: URL { bundleURL.deletingPathExtension().appendingPathExtension("old.app") }

    private static var unpackDirectory: URL { AppPaths.dataDirectory.appendingPathComponent("update/unpacked", isDirectory: true) }

    /// True for a real .app bundle in a folder this user can write to. The bare development binary
    /// and read-only locations fall back to the download page.
    static func canUpdateInPlace() -> Bool {
        guard AppInfo.isBundled else { return false }
        let fm = FileManager.default
        let parent = bundleURL.deletingLastPathComponent()
        return fm.isWritableFile(atPath: parent.path) && fm.isWritableFile(atPath: bundleURL.path)
    }

    /// Swaps the downloaded archive in and starts the new copy. The caller must exit right after.
    static func install(downloaded: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: unpackDirectory)
        try fm.createDirectory(at: unpackDirectory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", downloaded.path, unpackDirectory.path])

        guard let newApp = try fm.contentsOfDirectory(at: unpackDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(L("下载的文件里没有找到应用。", "The downloaded archive does not contain the app."))
        }
        let executable = newApp.appendingPathComponent("Contents/MacOS/QingYiTranslator")
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw UpdateError(L("下载的应用不完整。", "The downloaded app is incomplete."))
        }
        // Files we downloaded ourselves carry no quarantine flag, but be safe.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let current = bundleURL
        try? fm.removeItem(at: backupURL)
        try fm.moveItem(at: current, to: backupURL)
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: backupURL, to: current)
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", current.path, "--args", "--updated", "--wait-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        do {
            try process.run()
        } catch {
            try? fm.moveItem(at: current, to: newApp)
            try? fm.moveItem(at: backupURL, to: current)
            throw error
        }
        Log.info("已安装更新，正在重启：\(current.path)")
    }

    /// Deletes what an earlier update left behind. The old process may still be closing, so this keeps trying for a while.
    static func cleanUpInBackground() {
        guard AppInfo.isBundled else { return }
        let leftovers = [backupURL, downloadPath, unpackDirectory]
        let fm = FileManager.default
        guard leftovers.contains(where: { fm.fileExists(atPath: $0.path) }) else { return }
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<30 {
                for url in leftovers {
                    try? fm.removeItem(at: url)
                }
                if !leftovers.contains(where: { fm.fileExists(atPath: $0.path) }) {
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// After an update the new copy is started while the old one is still closing; let it finish first.
    static func waitForExit(pid: Int32) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(L("解压更新失败（\(tool) 返回 \(process.terminationStatus)）。", "Could not unpack the update (\(tool) returned \(process.terminationStatus))."))
        }
    }
}
