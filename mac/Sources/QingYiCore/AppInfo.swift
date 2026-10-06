import Foundation

public enum AppInfo {
    /// Used when running the bare executable (no bundle), e.g. `swift run`.
    public static let fallbackVersion = "0.3.0"
    public static let bundleIdentifier = "com.jingxuanwh.QingYiTranslator"

    public static var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }

    public static var version: SemanticVersion { SemanticVersion.parse(versionText) ?? SemanticVersion(0, 0, 0) }

    /// True when running from a .app bundle rather than as a bare executable.
    public static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

/// "major.minor.patch"; a tag such as "v0.3.0" or "0.3" parses too.
public struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(_ tag: String?) -> SemanticVersion? {
        guard var text = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        while let first = text.first, first == "v" || first == "V" { text.removeFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) {
            text = String(text[..<suffix])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return SemanticVersion(numbers[0], numbers[1], numbers[2])
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
