import AppKit
import QingYiCore

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--translate") {
    CommandLineMode.run(arguments: Array(arguments[(index + 1)...]))
}
// Development aid: installs a downloaded archive exactly like the in-app updater does, then exits.
if let index = arguments.firstIndex(of: "--install-update"), index + 1 < arguments.count {
    do {
        try SelfUpdater.install(downloaded: URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
if arguments.contains("--version") {
    print("QingYi Translator \(AppInfo.versionText)")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
