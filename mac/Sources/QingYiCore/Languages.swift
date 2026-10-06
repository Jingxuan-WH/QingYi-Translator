import Foundation

/// A language the app can translate from and to.
public struct Language: Hashable, Identifiable {
    public let code: String
    /// The Chinese name.
    public let displayName: String
    public let englishName: String

    public init(code: String, displayName: String, englishName: String) {
        self.code = code
        self.displayName = displayName
        self.englishName = englishName
    }

    public var id: String { code }

    public var isChinese: Bool { code.hasPrefix("zh") }

    /// The name in the current interface language.
    public var localName: String { Loc.isEnglish ? englishName : displayName }

    /// Simplified and Traditional Chinese count as one language when deciding whether text needs translating.
    public func isSameLanguage(as other: Language) -> Bool { code == other.code || (isChinese && other.isChinese) }

    public static func == (a: Language, b: Language) -> Bool { a.code == b.code }

    public func hash(into hasher: inout Hasher) { hasher.combine(code) }
}

public enum Languages {
    public static let autoCode = "auto"

    public static let simplifiedChinese = Language(code: "zh-Hans", displayName: "简体中文", englishName: "Simplified Chinese")
    public static let traditionalChinese = Language(code: "zh-Hant", displayName: "繁体中文", englishName: "Traditional Chinese")
    public static let english = Language(code: "en", displayName: "英语", englishName: "English")
    public static let japanese = Language(code: "ja", displayName: "日语", englishName: "Japanese")
    public static let korean = Language(code: "ko", displayName: "韩语", englishName: "Korean")
    public static let french = Language(code: "fr", displayName: "法语", englishName: "French")
    public static let german = Language(code: "de", displayName: "德语", englishName: "German")
    public static let spanish = Language(code: "es", displayName: "西班牙语", englishName: "Spanish")
    public static let portuguese = Language(code: "pt", displayName: "葡萄牙语", englishName: "Portuguese")
    public static let italian = Language(code: "it", displayName: "意大利语", englishName: "Italian")
    public static let russian = Language(code: "ru", displayName: "俄语", englishName: "Russian")
    public static let arabic = Language(code: "ar", displayName: "阿拉伯语", englishName: "Arabic")
    public static let vietnamese = Language(code: "vi", displayName: "越南语", englishName: "Vietnamese")
    public static let thai = Language(code: "th", displayName: "泰语", englishName: "Thai")
    public static let indonesian = Language(code: "id", displayName: "印尼语", englishName: "Indonesian")
    public static let turkish = Language(code: "tr", displayName: "土耳其语", englishName: "Turkish")
    public static let dutch = Language(code: "nl", displayName: "荷兰语", englishName: "Dutch")
    public static let polish = Language(code: "pl", displayName: "波兰语", englishName: "Polish")
    public static let hindi = Language(code: "hi", displayName: "印地语", englishName: "Hindi")

    public static let all: [Language] = [
        simplifiedChinese, traditionalChinese, english, japanese, korean, french, german, spanish, portuguese,
        italian, russian, arabic, vietnamese, thai, indonesian, turkish, dutch, polish, hindi,
    ]

    public static func find(_ code: String?) -> Language? { all.first { $0.code == code } }

    /// Where to send text that is already written in `target`: Chinese goes to English, everything else to Chinese.
    public static func fallback(for target: Language) -> Language { target.isChinese ? english : simplifiedChinese }
}

/// Cheap offline language guess, used for the "detected" label and to decide the translation direction.
/// The model is not told the guessed source language, so a wrong guess never corrupts a translation.
public enum LanguageDetector {
    private static let sampleLength = 4000

    private static let traditionalOnly = Set<Character>(
        "這們說為會來時個學對開關後發經與過還見國邊麼樣問題長門東車馬鳥魚書買賣讀寫話語請讓認識電腦網頁線級義頭實體點將當從無現進產動應處樂歡歲親愛總")
    private static let simplifiedOnly = Set<Character>(
        "这们说为会来时个学对开关后发经与过还见国边么样问题长门东车马鸟鱼书买卖读写话语请让认识电脑网页线级义头实体点将当从无现进产动应处乐欢岁亲爱总")
    private static let vietnameseLetters = Set<Character>(
        "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")

    private static let stopwords: [(language: Language, words: Set<String>)] = [
        (Languages.english, set("the and of to is in that it for with as was on are this be by not have from or which an you we they he she at has were been their will would can but if there what all")),
        (Languages.french, set("le la les et des un une est du en que qui dans pour pas sur au avec ce il elle ne se sont par nous vous mais ou cette aux été être plus comme leur")),
        (Languages.german, set("der die das und ist nicht ein eine zu den mit sich des auf für im dem es von auch wird sind ich wir sie er werden aus bei oder wie aber nach einer noch kann dass")),
        (Languages.spanish, set("el la los las de que y en un una es por con para del se no al lo como más pero su sus este esta son fue ha muy también entre cuando ser hay está")),
        (Languages.portuguese, set("o a os as de que e do da em um uma é para com não no na por se dos das mais como mas ao ele ela são foi isso está também pelo pela seu sua muito")),
        (Languages.italian, set("il lo la gli le di che e è un una per non in con del della sono si da al ma come anche più questo questa nel nella dei delle alla essere stato ha hanno")),
        (Languages.dutch, set("de het een en van is dat op te in zijn niet met voor die er aan ook als bij maar wordt dit naar om ze we zich hij heeft worden deze nog kan uit")),
        (Languages.indonesian, set("yang dan di ini itu dengan untuk dari tidak dalam akan pada juga ke ada adalah oleh atau saya kami mereka bisa sudah karena telah lebih seperti tersebut dapat harus")),
        (Languages.turkish, set("ve bir bu da de için ile çok ne gibi daha olarak olan var ama değil kadar sonra ben sen biz onlar mı mi olduğu bunu şey her")),
        (Languages.polish, set("i w z na się nie to do że jest o jak ale po co tak za od przez jego są czy być tylko już może tym który która które dla")),
    ]

    public static func detect(_ text: String) -> Language? {
        let sample = String(text.prefix(sampleLength))
        var han = 0, kana = 0, hangul = 0, cyrillic = 0, arabic = 0, thai = 0, devanagari = 0, latin = 0
        for scalar in sample.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han += 1
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0600...0x06FF, 0x0750...0x077F: arabic += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0x0900...0x097F: devanagari += 1
            default:
                if isLetter(scalar) && (v < 0x250 || (0x1E00...0x1EFF).contains(v)) {
                    latin += 1
                }
            }
        }

        // A CJK character or Hangul syllable carries about as much meaning as a four-letter word,
        // so a few English terms don't flip Chinese text to English (and vice versa).
        let scores: [(script: String, score: Double)] = [
            ("cjk", Double(han + kana)),
            ("hangul", Double(hangul)),
            ("cyrillic", Double(cyrillic) / 4),
            ("arabic", Double(arabic) / 4),
            ("thai", Double(thai) / 4),
            ("devanagari", Double(devanagari) / 4),
            ("latin", Double(latin) / 4),
        ]
        var best = scores[0]
        for score in scores.dropFirst() where score.score > best.score {
            best = score
        }
        if best.score <= 0 {
            return nil
        }
        switch best.script {
        // Japanese mixes kana into kanji; Chinese text only has the odd katakana name.
        case "cjk": return kana >= 2 && kana * 5 >= han ? Languages.japanese : detectChineseScript(sample)
        case "hangul": return Languages.korean
        case "cyrillic": return Languages.russian
        case "arabic": return Languages.arabic
        case "thai": return Languages.thai
        case "devanagari": return Languages.hindi
        default: return detectLatinLanguage(sample)
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func detectChineseScript(_ text: String) -> Language {
        var traditional = 0, simplified = 0
        for c in text {
            if traditionalOnly.contains(c) {
                traditional += 1
            } else if simplifiedOnly.contains(c) {
                simplified += 1
            }
        }
        return traditional > simplified ? Languages.traditionalChinese : Languages.simplifiedChinese
    }

    private static func detectLatinLanguage(_ text: String) -> Language {
        var scores: [Language: Double] = [:]
        func add(_ language: Language, _ points: Double) { scores[language, default: 0] += points }

        var letters = 0, vietnamese = 0
        for raw in text {
            let c = raw.lowercased().first ?? raw
            if c.isLetter {
                letters += 1
            }
            if vietnameseLetters.contains(c) {
                vietnamese += 1
            }
            switch c {
            case "ß": add(Languages.german, 2)
            case "ä": add(Languages.german, 1)
            case "ö", "ü": add(Languages.german, 0.5); add(Languages.turkish, 0.5)
            case "ğ", "ş", "ı": add(Languages.turkish, 2)
            case "ą", "ę", "ł", "ń", "ś", "ź", "ż": add(Languages.polish, 2)
            case "ñ", "¿", "¡": add(Languages.spanish, 2)
            case "ã", "õ": add(Languages.portuguese, 2)
            case "œ", "ê", "û", "î", "ï", "ë": add(Languages.french, 0.5)
            case "ç": add(Languages.french, 0.5); add(Languages.portuguese, 0.5)
            case "è", "à", "ù": add(Languages.french, 0.3); add(Languages.italian, 0.3)
            case "ò", "ì": add(Languages.italian, 1)
            default: break
            }
        }

        // Vietnamese is unmistakable by its extra letters and tone marks.
        if vietnamese >= 2 && vietnamese * 20 >= letters {
            return Languages.vietnamese
        }

        for word in words(text) {
            for (language, set) in stopwords where set.contains(word) {
                add(language, 1)
            }
        }

        // Ties go to the language listed first, like the Windows version.
        var best: (language: Language, score: Double)?
        for (language, _) in stopwords {
            if let score = scores[language], score > 0, best == nil || score > best!.score {
                best = (language, score)
            }
        }
        return best?.language ?? Languages.english
    }

    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for c in text {
            if c.isLetter {
                current.append(c)
            } else if !current.isEmpty {
                result.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(current.lowercased())
        }
        return result
    }

    private static func set(_ words: String) -> Set<String> { Set(words.split(separator: " ").map(String.init)) }
}
