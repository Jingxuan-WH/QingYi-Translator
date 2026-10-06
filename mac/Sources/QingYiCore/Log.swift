import Foundation

public enum Log {
    private static let maxFileBytes: UInt64 = 1_000_000
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static var filePath: String { AppPaths.dataDirectory.appendingPathComponent("logs/app.log").path }

    public static func info(_ message: String) { write("INFO", message) }

    public static func error(_ message: String, _ error: Error? = nil) {
        write("ERROR", error.map { "\(message)\n\($0)" } ?? message)
    }

    private static func write(_ level: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = URL(fileURLWithPath: filePath)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxFileBytes {
                try? fm.removeItem(atPath: url.path + ".old")
                try? fm.moveItem(atPath: url.path, toPath: url.path + ".old")
            }
            let line = "\(formatter.string(from: Date())) [\(level)] \(text)\n"
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging must never take the app down.
        }
    }
}
