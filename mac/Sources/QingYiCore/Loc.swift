import Combine
import Foundation

/// A text in both interface languages; `text` gives the one currently shown.
public struct LocText: Equatable {
    public let zh: String
    public let en: String

    public init(_ zh: String, _ en: String) {
        self.zh = zh
        self.en = en
    }

    public init(_ same: String) {
        zh = same
        en = same
    }

    public var text: String { Loc.shared.isEnglish ? en : zh }
}

/// The interface language (Chinese or English). Views observe the shared instance, so switching
/// the language re-renders every open window at once.
public final class Loc: ObservableObject {
    public static let shared = Loc()

    public static let systemCode = "system"
    public static let chineseCode = "zh"
    public static let englishCode = "en"

    @Published public private(set) var isEnglish = false

    private init() {}

    public static var isEnglish: Bool { shared.isEnglish }

    public static func t(_ zh: String, _ en: String) -> String { shared.isEnglish ? en : zh }

    /// Settings value → language: "zh", "en", or anything else to follow the macOS display language.
    public static func resolvesToEnglish(_ setting: String?) -> Bool {
        switch setting {
        case englishCode: return true
        case chineseCode: return false
        default:
            let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
            return !preferred.lowercased().hasPrefix("zh")
        }
    }

    public func apply(_ setting: String?) {
        let english = Loc.resolvesToEnglish(setting)
        if english != isEnglish {
            isEnglish = english
        }
    }
}

/// Short form of `Loc.t`.
@inline(__always)
public func L(_ zh: String, _ en: String) -> String { Loc.t(zh, en) }
