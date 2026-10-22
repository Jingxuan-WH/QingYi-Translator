using System.Text;
using System.Text.RegularExpressions;

namespace Translator.Core;

/// <summary>Tidies recognized text and drops what Whisper tends to "hear" in noise or music.</summary>
public static class SpeechText
{
    // Whisper learned these from subtitled videos and produces them for silence, music and applause.
    private static readonly HashSet<string> Hallucinations = new(StringComparer.Ordinal)
    {
        "谢谢观看", "谢谢大家观看", "感谢观看", "谢谢收看", "感谢您的观看", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "明镜需要您的支持欢迎订阅明镜", "字幕由amaraorg社区提供", "小编字幕由amaraorg社区提供", "中文字幕志愿者李宗盛",
        "请订阅我的频道", "订阅我的频道", "字幕", "字幕制作", "本字幕由", "优优独播剧场youyoutvseries",
        "thankyouforwatching", "thanksforwatching", "thankyouforwatchingpleasesubscribe", "pleasesubscribe",
        "subtitlesbytheamaraorgcommunity", "you", "byebye", "thankyouverymuchforwatching",
    };

    private static readonly Regex Tag = new(@"\[[^\]]*\]|[(（][^)）]*(music|音乐|掌声|笑声|applause|laughter|silence|blank)[^)）]*[)）]|♪+|\*[^*]*\*",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex Spaces = new(@"\s+", RegexOptions.Compiled);

    /// <summary>Removes tags such as [BLANK_AUDIO] or (music) and collapses whitespace.</summary>
    public static string Clean(string text)
    {
        text = Tag.Replace(text, " ");
        text = Spaces.Replace(text, " ").Trim();
        return text.TrimStart('-', ' ', '>');
    }

    public static bool IsLikelyHallucination(string text)
    {
        string key = Normalize(text);
        return key.Length == 0 || Hallucinations.Contains(key);
    }

    // Lowercase letters and digits only, so punctuation and spacing don't matter.
    private static string Normalize(string text)
    {
        var key = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (char.IsLetterOrDigit(c))
                key.Append(char.ToLowerInvariant(c));
        }
        return key.ToString();
    }
}
