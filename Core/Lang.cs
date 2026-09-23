namespace Translator.Core;

public enum Lang
{
    Auto,
    Zh,
    En,
}

public static class LanguageDetector
{
    /// <summary>Decides whether a text is mainly Chinese or English.</summary>
    public static Lang Detect(string text)
    {
        int cjk = 0, latin = 0;
        foreach (char c in text)
        {
            if (c is >= '一' and <= '鿿' or >= '㐀' and <= '䶿' or >= '豈' and <= '﫿')
                cjk++;
            else if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z')
                latin++;
        }

        // One Chinese character carries roughly as much meaning as a four-letter English word,
        // so English terms sprinkled through Chinese text do not flip the result (and vice versa).
        return cjk > 0 && cjk * 4 >= latin ? Lang.Zh : Lang.En;
    }

    public static Lang Other(Lang lang) => lang == Lang.Zh ? Lang.En : Lang.Zh;
}
