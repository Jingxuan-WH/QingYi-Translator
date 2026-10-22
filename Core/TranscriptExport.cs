using System.Globalization;
using System.Text;

namespace Translator.Core;

public enum TranscriptFormat
{
    Text,
    Srt,
}

public enum TranscriptContent
{
    Original,
    Translation,
    Bilingual,
}

/// <summary>Writes the final lines of a live transcript as plain text or SRT subtitles.</summary>
public static class TranscriptExport
{
    /// <summary>A subtitle stays on screen at least this long, unless the next one starts earlier.</summary>
    public const double MinCueSeconds = 0.8;

    public static string Build(IEnumerable<TranscriptLine> lines, TranscriptFormat format, TranscriptContent content)
    {
        var cues = lines.Where(line => line.IsFinal)
            .Select(line => (line.Start, line.End, Text: Pick(line, content)))
            .Where(cue => cue.Text.Length > 0)
            .ToList();
        var output = new StringBuilder();
        for (int i = 0; i < cues.Count; i++)
        {
            var (start, end, text) = cues[i];
            if (format == TranscriptFormat.Srt)
            {
                end = Math.Max(end, start + MinCueSeconds);
                if (i + 1 < cues.Count && end > cues[i + 1].Start)
                    end = Math.Max(start + 0.1, cues[i + 1].Start);
                output.Append(i + 1).Append("\r\n")
                    .Append(FormatSrtTime(start)).Append(" --> ").Append(FormatSrtTime(end)).Append("\r\n")
                    .Append(text).Append("\r\n\r\n");
            }
            else
            {
                output.Append('[').Append(FormatClock(start)).Append("] ").Append(text.Replace("\r\n", "\r\n    ")).Append("\r\n");
                if (content == TranscriptContent.Bilingual)
                    output.Append("\r\n");
            }
        }
        return output.ToString();
    }

    /// <summary>"00:01:02,345", the SRT time format.</summary>
    public static string FormatSrtTime(double seconds)
    {
        long ms = (long)Math.Round(Math.Max(0, seconds) * 1000);
        return string.Create(CultureInfo.InvariantCulture, $"{ms / 3_600_000:00}:{ms / 60_000 % 60:00}:{ms / 1000 % 60:00},{ms % 1000:000}");
    }

    /// <summary>"01:02", or "1:01:02" past an hour.</summary>
    public static string FormatClock(double seconds)
    {
        long total = (long)Math.Max(0, seconds);
        return total >= 3600
            ? string.Create(CultureInfo.InvariantCulture, $"{total / 3600}:{total / 60 % 60:00}:{total % 60:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{total / 60:00}:{total % 60:00}");
    }

    private static string Pick(TranscriptLine line, TranscriptContent content)
    {
        string original = line.Text.Trim();
        string translation = line.TranslationIsDraft ? "" : line.Translation.Trim();
        return content switch
        {
            TranscriptContent.Original => original,
            TranscriptContent.Translation => translation,
            _ => translation.Length == 0 ? original : original + "\r\n" + translation,
        };
    }
}
