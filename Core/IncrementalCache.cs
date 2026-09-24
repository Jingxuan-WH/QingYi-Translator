using System.Text;
using System.Text.RegularExpressions;

namespace Translator.Core;

/// <summary>One paragraph (or block of paragraphs) of source text together with its translation.</summary>
public sealed record TranslationTurn(string Source, string Translation);

/// <summary>What still needs translating after reusing the unchanged leading paragraphs of the previous translation.</summary>
public sealed class IncrementalPlan
{
    private const int MaxContextTurns = 3;
    private const int MaxContextChars = 4000;

    public IncrementalPlan(IReadOnlyList<TranslationTurn> reused, string reusedTranslation, string remainder)
    {
        Reused = reused;
        ReusedTranslation = reusedTranslation;
        Remainder = remainder;
    }

    public static IncrementalPlan Full(string text) => new([], "", text);

    /// <summary>Leading paragraphs whose translation is kept as is.</summary>
    public IReadOnlyList<TranslationTurn> Reused { get; }

    /// <summary>The kept translation, ending with the separator that precedes the remainder.</summary>
    public string ReusedTranslation { get; }

    /// <summary>The text that still has to be sent to the model.</summary>
    public string Remainder { get; }

    public bool IsFull => Reused.Count == 0;

    public bool NothingNew => !IsFull && string.IsNullOrWhiteSpace(Remainder);

    /// <summary>The last few reused paragraphs, sent along so the model keeps terminology consistent.</summary>
    public IReadOnlyList<TranslationTurn> Context
    {
        get
        {
            var turns = new List<TranslationTurn>();
            int chars = 0;
            for (int i = Reused.Count - 1; i >= 0 && turns.Count < MaxContextTurns; i--)
            {
                chars += Reused[i].Source.Length;
                if (turns.Count > 0 && chars > MaxContextChars)
                    break;
                turns.Insert(0, Reused[i]);
            }
            return turns;
        }
    }
}

/// <summary>
/// Remembers the paragraphs of the last translation so that appending text (or editing a later paragraph)
/// only sends the changed tail to the model, with the preceding paragraphs as context.
/// </summary>
public sealed class IncrementalCache
{
    private static readonly Regex BlankLine = new(@"\r?\n[ \t]*\r?\n\s*", RegexOptions.Compiled);

    private readonly List<TranslationTurn> _segments = [];
    private string? _contextKey;

    public void Clear()
    {
        _segments.Clear();
        _contextKey = null;
    }

    /// <param name="contextKey">Languages, provider, model and instructions; any change forces a full translation.</param>
    public IncrementalPlan Plan(string contextKey, string text)
    {
        if (contextKey != _contextKey || _segments.Count == 0)
            return IncrementalPlan.Full(text);

        var reused = new List<TranslationTurn>();
        var translation = new StringBuilder();
        int position = 0;
        foreach (var segment in _segments)
        {
            if (string.CompareOrdinal(text, position, segment.Source, 0, segment.Source.Length) != 0
                || text.Length < position + segment.Source.Length)
                break;

            int end = position + segment.Source.Length;
            int next = end;
            while (next < text.Length && char.IsWhiteSpace(text[next]))
                next++;
            bool atEnd = next == text.Length;
            int newlines = text.AsSpan(end, next - end).Count('\n');

            // Only reuse a paragraph that is finished: text continuing on the same line, or a single
            // line break after an unfinished sentence (a soft wrap, as in text copied from a PDF),
            // means the paragraph is still being written.
            if (!atEnd && (newlines == 0 || (newlines == 1 && !EndsSentence(segment.Source))))
                break;

            reused.Add(segment);
            translation.Append(segment.Translation).Append(newlines >= 2 ? "\n\n" : newlines == 1 ? "\n" : "");
            position = next;
            if (atEnd)
                break;
        }

        return reused.Count == 0
            ? IncrementalPlan.Full(text)
            : new IncrementalPlan(reused, translation.ToString(), text[position..]);
    }

    /// <summary>Records a finished translation of <paramref name="plan"/>'s remainder (or of the whole text for a full plan).</summary>
    public void Commit(string contextKey, IncrementalPlan plan, string remainderTranslation)
    {
        var segments = new List<TranslationTurn>(plan.Reused);
        if (!string.IsNullOrWhiteSpace(plan.Remainder))
            segments.AddRange(Split(plan.Remainder, remainderTranslation));
        _segments.Clear();
        _segments.AddRange(segments);
        _contextKey = contextKey;
    }

    /// <summary>
    /// Splits a translated block into paragraph pairs when source and translation have the same number of
    /// paragraphs, so a later edit can reuse more of it; otherwise keeps it as one block.
    /// </summary>
    internal static IReadOnlyList<TranslationTurn> Split(string source, string translation)
    {
        source = source.TrimEnd();
        translation = translation.Trim();
        string[] sourceParts = BlankLine.Split(source);
        string[] translatedParts = BlankLine.Split(translation);
        if (sourceParts.Length > 1 && sourceParts.Length == translatedParts.Length)
            return sourceParts.Zip(translatedParts, (s, t) => new TranslationTurn(s.TrimEnd(), t.Trim())).ToList();
        return [new TranslationTurn(source, translation)];
    }

    private static bool EndsSentence(string text)
    {
        ReadOnlySpan<char> span = text.AsSpan().TrimEnd();
        while (span.Length > 0 && "\"'”’)）]】」』》".Contains(span[^1]))
            span = span[..^1];
        return span.Length > 0 && ".!?。！？…:;：；".Contains(span[^1]);
    }
}
