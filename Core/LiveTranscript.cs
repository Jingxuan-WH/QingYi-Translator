using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Translator.Core;

/// <summary>One utterance of a live transcript with its translation. Shown in a list, so every change is announced.</summary>
public sealed class TranscriptLine : INotifyPropertyChanged
{
    private string _text = "";
    private bool _isFinal;
    private double _end;
    private string _translation = "";
    private bool _translationIsDraft;
    private bool _isTranslating;

    public TranscriptLine(int session, int utterance, double start)
    {
        Session = session;
        Utterance = utterance;
        Start = start;
        _end = start;
    }

    public int Session { get; }
    public int Utterance { get; }

    /// <summary>Seconds from the start of the transcript.</summary>
    public double Start { get; internal set; }

    public double End
    {
        get => _end;
        internal set => Set(ref _end, value);
    }

    /// <summary>Recognized text; while <see cref="IsFinal"/> is false it may still change.</summary>
    public string Text
    {
        get => _text;
        internal set => Set(ref _text, value);
    }

    public bool IsFinal
    {
        get => _isFinal;
        internal set => Set(ref _isFinal, value);
    }

    /// <summary>Language code the recognizer reported, when it did.</summary>
    public string? Language { get; internal set; }

    public string Translation
    {
        get => _translation;
        set => Set(ref _translation, value);
    }

    /// <summary>The translation is of a partial result and will be replaced.</summary>
    public bool TranslationIsDraft
    {
        get => _translationIsDraft;
        set => Set(ref _translationIsDraft, value);
    }

    public bool IsTranslating
    {
        get => _isTranslating;
        set => Set(ref _isTranslating, value);
    }

    public string TimeText => TranscriptExport.FormatClock(Start);

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

/// <summary>
/// The lines of a live transcript. Recognizers report partial results that are later replaced by a final one;
/// lines are keyed by utterance, so a late partial never overwrites a final result and an utterance that turns
/// out to be empty disappears again. Use from the UI thread only.
/// </summary>
public sealed class LiveTranscript
{
    private int _session;
    private double _offset;

    public ObservableCollection<TranscriptLine> Lines { get; } = [];

    public IEnumerable<TranscriptLine> FinalLines => Lines.Where(line => line.IsFinal);

    /// <summary>
    /// Call before feeding a new recognition session, whose utterance numbers and times start again from zero;
    /// its lines continue after the existing ones.
    /// </summary>
    public void BeginSession()
    {
        _session++;
        _offset = Lines.Count == 0 ? 0 : Math.Ceiling(Lines.Max(line => Math.Max(line.End, line.Start)) + 1);
    }

    /// <param name="start">Seconds from the start of the current session.</param>
    public TranscriptLine? UpdatePartial(int utterance, string text, double start)
    {
        text = text.Trim();
        var line = Find(utterance);
        if (line is null)
        {
            if (text.Length == 0)
                return null;
            line = Insert(utterance, start);
        }
        else if (line.IsFinal)
        {
            return null; // a late partial result; the final one wins
        }
        line.Text = text;
        return line;
    }

    /// <summary>Records the final text; returns null (and removes the partial line) when nothing was recognized.</summary>
    public TranscriptLine? Finalize(int utterance, string text, double start, double end, string? language = null)
    {
        text = text.Trim();
        var line = Find(utterance);
        if (text.Length == 0)
        {
            if (line is not null && !line.IsFinal)
                Lines.Remove(line);
            return null;
        }
        line ??= Insert(utterance, start);
        line.Start = start + _offset;
        line.End = Math.Max(end, start) + _offset;
        line.Text = text;
        line.Language = language;
        line.IsFinal = true;
        return line;
    }

    public void Discard(int utterance)
    {
        if (Find(utterance) is { IsFinal: false } line)
            Lines.Remove(line);
    }

    public TranscriptLine? Find(int utterance)
    {
        for (int i = Lines.Count - 1; i >= 0; i--)
        {
            var line = Lines[i];
            if (line.Session == _session && line.Utterance == utterance)
                return line;
            if (line.Session < _session)
                break;
        }
        return null;
    }

    public void Clear()
    {
        Lines.Clear();
        _offset = 0;
    }

    // Lines stay in utterance order even if a recognizer reports out of order.
    private TranscriptLine Insert(int utterance, double start)
    {
        var line = new TranscriptLine(_session, utterance, start + _offset);
        int index = Lines.Count;
        while (index > 0 && Lines[index - 1].Session == _session && Lines[index - 1].Utterance > utterance)
            index--;
        Lines.Insert(index, line);
        return line;
    }
}

/// <summary>The sentences translated just before, sent along with each new one so the translation stays coherent.</summary>
public sealed class LiveTranslationContext
{
    public const int MaxTurns = 3;
    public const int MaxChars = 1500;

    /// <summary>Appended to the user's own extra instructions for live translation.</summary>
    public const string Instructions =
        "The text comes from live speech recognition: it may contain recognition errors, filler words or missing punctuation. " +
        "Translate what the speaker means, naturally and concisely.";

    private readonly Queue<TranslationTurn> _turns = new();

    public void Add(string source, string translation)
    {
        if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(translation))
            return;
        _turns.Enqueue(new TranslationTurn(source.Trim(), translation.Trim()));
        while (_turns.Count > MaxTurns)
            _turns.Dequeue();
    }

    /// <summary>The most recent turns, oldest first, within <see cref="MaxChars"/> (at least one).</summary>
    public IReadOnlyList<TranslationTurn> Turns
    {
        get
        {
            var all = _turns.ToArray();
            var result = new List<TranslationTurn>();
            int chars = 0;
            for (int i = all.Length - 1; i >= 0; i--)
            {
                chars += all[i].Source.Length + all[i].Translation.Length;
                if (result.Count > 0 && chars > MaxChars)
                    break;
                result.Insert(0, all[i]);
            }
            return result;
        }
    }

    public void Clear() => _turns.Clear();

    public static string BuildInstructions(string userInstructions) =>
        string.IsNullOrWhiteSpace(userInstructions) ? Instructions : userInstructions.Trim() + "\n" + Instructions;

    /// <summary>
    /// Like the main window: speech already in the chosen target language goes to the fallback (Chinese → English,
    /// anything else → Chinese). With automatic detection the model is left to identify the source itself.
    /// </summary>
    public static (Language? PromptSource, Language Target) ResolveLanguages(string text, Language? source, Language preferredTarget)
    {
        var spoken = source ?? LanguageDetector.Detect(text);
        var target = spoken is not null && spoken.IsSameLanguageAs(preferredTarget) ? Languages.FallbackFor(preferredTarget) : preferredTarget;
        return (source, target);
    }
}
