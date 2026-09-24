using System.Buffers;

namespace Translator.Core;

/// <summary>A language the app can translate from and to.</summary>
public sealed record Language(string Code, string DisplayName, string EnglishName)
{
    public bool IsChinese => Code.StartsWith("zh", StringComparison.Ordinal);

    /// <summary>The name in the current interface language.</summary>
    public string LocalName => Loc.IsEnglish ? EnglishName : DisplayName;

    /// <summary>Simplified and Traditional Chinese count as one language when deciding whether text needs translating.</summary>
    public bool IsSameLanguageAs(Language other) => Code == other.Code || (IsChinese && other.IsChinese);
}

public static class Languages
{
    public const string AutoCode = "auto";

    public static Language SimplifiedChinese { get; } = new("zh-Hans", "简体中文", "Simplified Chinese");
    public static Language TraditionalChinese { get; } = new("zh-Hant", "繁体中文", "Traditional Chinese");
    public static Language English { get; } = new("en", "英语", "English");
    public static Language Japanese { get; } = new("ja", "日语", "Japanese");
    public static Language Korean { get; } = new("ko", "韩语", "Korean");
    public static Language French { get; } = new("fr", "法语", "French");
    public static Language German { get; } = new("de", "德语", "German");
    public static Language Spanish { get; } = new("es", "西班牙语", "Spanish");
    public static Language Portuguese { get; } = new("pt", "葡萄牙语", "Portuguese");
    public static Language Italian { get; } = new("it", "意大利语", "Italian");
    public static Language Russian { get; } = new("ru", "俄语", "Russian");
    public static Language Arabic { get; } = new("ar", "阿拉伯语", "Arabic");
    public static Language Vietnamese { get; } = new("vi", "越南语", "Vietnamese");
    public static Language Thai { get; } = new("th", "泰语", "Thai");
    public static Language Indonesian { get; } = new("id", "印尼语", "Indonesian");
    public static Language Turkish { get; } = new("tr", "土耳其语", "Turkish");
    public static Language Dutch { get; } = new("nl", "荷兰语", "Dutch");
    public static Language Polish { get; } = new("pl", "波兰语", "Polish");
    public static Language Hindi { get; } = new("hi", "印地语", "Hindi");

    // Must stay below the individual languages: static initializers run in textual order.
    public static IReadOnlyList<Language> All { get; } =
    [
        SimplifiedChinese, TraditionalChinese, English, Japanese, Korean, French, German, Spanish, Portuguese,
        Italian, Russian, Arabic, Vietnamese, Thai, Indonesian, Turkish, Dutch, Polish, Hindi,
    ];

    public static Language? Find(string? code) => All.FirstOrDefault(language => language.Code == code);

    /// <summary>Where to send text that is already written in <paramref name="target"/>: Chinese goes to English, everything else to Chinese.</summary>
    public static Language FallbackFor(Language target) => target.IsChinese ? English : SimplifiedChinese;
}

/// <summary>
/// Cheap offline language guess, used for the "detected" label and to decide the translation direction.
/// The model is not told the guessed source language, so a wrong guess never corrupts a translation.
/// </summary>
public static class LanguageDetector
{
    private const int SampleLength = 4000;

    private static readonly SearchValues<char> TraditionalOnly = SearchValues.Create(
        "這們說為會來時個學對開關後發經與過還見國邊麼樣問題長門東車馬鳥魚書買賣讀寫話語請讓認識電腦網頁線級義頭實體點將當從無現進產動應處樂歡歲親愛總");
    private static readonly SearchValues<char> SimplifiedOnly = SearchValues.Create(
        "这们说为会来时个学对开关后发经与过还见国边么样问题长门东车马鸟鱼书买卖读写话语请让认识电脑网页线级义头实体点将当从无现进产动应处乐欢岁亲爱总");
    private static readonly SearchValues<char> VietnameseLetters = SearchValues.Create(
        "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ");

    private static readonly (Language Language, HashSet<string> Words)[] Stopwords =
    [
        (Languages.English, Set("the and of to is in that it for with as was on are this be by not have from or which an you we they he she at has were been their will would can but if there what all")),
        (Languages.French, Set("le la les et des un une est du en que qui dans pour pas sur au avec ce il elle ne se sont par nous vous mais ou cette aux été être plus comme leur")),
        (Languages.German, Set("der die das und ist nicht ein eine zu den mit sich des auf für im dem es von auch wird sind ich wir sie er werden aus bei oder wie aber nach einer noch kann dass")),
        (Languages.Spanish, Set("el la los las de que y en un una es por con para del se no al lo como más pero su sus este esta son fue ha muy también entre cuando ser hay está")),
        (Languages.Portuguese, Set("o a os as de que e do da em um uma é para com não no na por se dos das mais como mas ao ele ela são foi isso está também pelo pela seu sua muito")),
        (Languages.Italian, Set("il lo la gli le di che e è un una per non in con del della sono si da al ma come anche più questo questa nel nella dei delle alla essere stato ha hanno")),
        (Languages.Dutch, Set("de het een en van is dat op te in zijn niet met voor die er aan ook als bij maar wordt dit naar om ze we zich hij heeft worden deze nog kan uit")),
        (Languages.Indonesian, Set("yang dan di ini itu dengan untuk dari tidak dalam akan pada juga ke ada adalah oleh atau saya kami mereka bisa sudah karena telah lebih seperti tersebut dapat harus")),
        (Languages.Turkish, Set("ve bir bu da de için ile çok ne gibi daha olarak olan var ama değil kadar sonra ben sen biz onlar mı mi olduğu bunu şey her")),
        (Languages.Polish, Set("i w z na się nie to do że jest o jak ale po co tak za od przez jego są czy być tylko już może tym który która które dla")),
    ];

    public static Language? Detect(string text)
    {
        ReadOnlySpan<char> sample = text.AsSpan(0, Math.Min(text.Length, SampleLength));
        int han = 0, kana = 0, hangul = 0, cyrillic = 0, arabic = 0, thai = 0, devanagari = 0, latin = 0;
        foreach (char c in sample)
        {
            switch (c)
            {
                case >= '一' and <= '鿿' or >= '㐀' and <= '䶿' or >= '豈' and <= '﫿': han++; break;
                case >= '぀' and <= 'ヿ': kana++; break;
                case >= '가' and <= '힯' or >= 'ᄀ' and <= 'ᇿ' or >= '㄰' and <= '㆏': hangul++; break;
                case >= 'Ѐ' and <= 'ӿ': cyrillic++; break;
                case >= '؀' and <= 'ۿ' or >= 'ݐ' and <= 'ݿ': arabic++; break;
                case >= '฀' and <= '๿': thai++; break;
                case >= 'ऀ' and <= 'ॿ': devanagari++; break;
                default:
                    if (char.IsLetter(c) && (c < 'ɐ' || c is >= 'Ḁ' and <= 'ỿ'))
                        latin++;
                    break;
            }
        }

        // A CJK character or Hangul syllable carries about as much meaning as a four-letter word,
        // so a few English terms don't flip Chinese text to English (and vice versa).
        (string Script, double Score)[] scores =
        [
            ("cjk", han + kana),
            ("hangul", hangul),
            ("cyrillic", cyrillic / 4.0),
            ("arabic", arabic / 4.0),
            ("thai", thai / 4.0),
            ("devanagari", devanagari / 4.0),
            ("latin", latin / 4.0),
        ];
        var best = scores.MaxBy(score => score.Score);
        if (best.Score <= 0)
            return null;

        return best.Script switch
        {
            // Japanese mixes kana into kanji; Chinese text only has the odd katakana name.
            "cjk" => kana >= 2 && kana * 5 >= han ? Languages.Japanese : DetectChineseScript(sample),
            "hangul" => Languages.Korean,
            "cyrillic" => Languages.Russian,
            "arabic" => Languages.Arabic,
            "thai" => Languages.Thai,
            "devanagari" => Languages.Hindi,
            _ => DetectLatinLanguage(sample),
        };
    }

    private static Language DetectChineseScript(ReadOnlySpan<char> text)
    {
        int traditional = 0, simplified = 0;
        foreach (char c in text)
        {
            if (TraditionalOnly.Contains(c))
                traditional++;
            else if (SimplifiedOnly.Contains(c))
                simplified++;
        }
        return traditional > simplified ? Languages.TraditionalChinese : Languages.SimplifiedChinese;
    }

    private static Language DetectLatinLanguage(ReadOnlySpan<char> text)
    {
        var scores = new Dictionary<Language, double>();
        void Add(Language language, double points) => scores[language] = scores.GetValueOrDefault(language) + points;

        int letters = 0, vietnamese = 0;
        foreach (char raw in text)
        {
            char c = char.ToLowerInvariant(raw);
            if (char.IsLetter(c))
                letters++;
            if (VietnameseLetters.Contains(c))
                vietnamese++;
            switch (c)
            {
                case 'ß': Add(Languages.German, 2); break;
                case 'ä': Add(Languages.German, 1); break;
                case 'ö' or 'ü': Add(Languages.German, 0.5); Add(Languages.Turkish, 0.5); break;
                case 'ğ' or 'ş' or 'ı': Add(Languages.Turkish, 2); break;
                case 'ą' or 'ę' or 'ł' or 'ń' or 'ś' or 'ź' or 'ż': Add(Languages.Polish, 2); break;
                case 'ñ' or '¿' or '¡': Add(Languages.Spanish, 2); break;
                case 'ã' or 'õ': Add(Languages.Portuguese, 2); break;
                case 'œ' or 'ê' or 'û' or 'î' or 'ï' or 'ë': Add(Languages.French, 0.5); break;
                case 'ç': Add(Languages.French, 0.5); Add(Languages.Portuguese, 0.5); break;
                case 'è' or 'à' or 'ù': Add(Languages.French, 0.3); Add(Languages.Italian, 0.3); break;
                case 'ò' or 'ì': Add(Languages.Italian, 1); break;
            }
        }

        // Vietnamese is unmistakable by its extra letters and tone marks.
        if (vietnamese >= 2 && vietnamese * 20 >= letters)
            return Languages.Vietnamese;

        foreach (string word in Words(text))
        {
            foreach (var (language, words) in Stopwords)
            {
                if (words.Contains(word))
                    Add(language, 1);
            }
        }

        var best = scores.OrderByDescending(pair => pair.Value).FirstOrDefault();
        return best.Value > 0 ? best.Key : Languages.English;
    }

    private static List<string> Words(ReadOnlySpan<char> text)
    {
        var words = new List<string>();
        int start = -1;
        for (int i = 0; i <= text.Length; i++)
        {
            bool letter = i < text.Length && char.IsLetter(text[i]);
            if (letter && start < 0)
            {
                start = i;
            }
            else if (!letter && start >= 0)
            {
                words.Add(text[start..i].ToString().ToLowerInvariant());
                start = -1;
            }
        }
        return words;
    }

    private static HashSet<string> Set(string words) => new(words.Split(' '), StringComparer.Ordinal);
}
