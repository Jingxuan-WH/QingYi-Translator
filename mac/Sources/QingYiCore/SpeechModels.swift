import Foundation

/// What macOS reports about the speech model of a language (`AssetInventory.Status` on macOS 26). It is mirrored here
/// so the decisions below can be tested without the Speech framework.
public enum SpeechModelStatus: String, Sendable {
    case installed, downloading, supported, unsupported
}

/// Decisions around the macOS 26 speech models used by SpeechAnalyzer.
public enum SpeechModelPlan {
    public enum Action: Equatable, Sendable {
        /// The model is on this Mac: start recognizing.
        case ready
        /// Offer the one-time download (also while macOS is still downloading it).
        case download
        case unsupported
    }

    /// Only the status tells whether a model is installed: `AssetInventory.assetInstallationRequest(supporting:)` keeps
    /// returning a request for models that are already there. The status is only meaningful once the app has reserved
    /// the locale.
    public static func action(for status: SpeechModelStatus) -> Action {
        switch status {
        case .installed: return .ready
        case .supported, .downloading: return .download
        case .unsupported: return .unsupported
        }
    }

    /// The reservations to give up so that `needed` fits within `maximum` reservations: only ones this app doesn't need
    /// now, and only as many as necessary. Locales are compared by `key(languageCode:region:)`.
    public static func reservationsToRelease(reserved: [String], needed: [String], maximum: Int) -> [String] {
        let missing = Set(needed).subtracting(reserved).count
        let excess = Set(reserved).count + missing - maximum
        guard excess > 0 else { return [] }
        return Array(reserved.filter { !needed.contains($0) }.prefix(excess))
    }

    /// The languages a download just finished for that still report needing one. Offering the same download again
    /// would go round in circles.
    public static func stillMissing(_ missing: [String], afterDownloading downloaded: [String]) -> [String] {
        missing.filter(downloaded.contains)
    }

    /// Identifies a locale across its variants: macOS may report "zh-Hans-CN" for a reservation made as "zh-CN".
    public static func key(languageCode: String, region: String?) -> String {
        guard let region, !region.isEmpty else { return languageCode.lowercased() }
        return languageCode.lowercased() + "-" + region.uppercased()
    }
}
