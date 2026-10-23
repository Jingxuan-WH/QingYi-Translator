namespace Translator.Core.FileTranslation;

/// <summary>A stretch of text in one style: a font, or an object drawn on its own. The caller numbers the styles.</summary>
public readonly record struct TextRun(string Text, int Style);

/// <summary>A line of fitted text: its pieces, their styles and where each starts, relative to the line's left edge.</summary>
public sealed record FittedLine(IReadOnlyList<(string Text, int Style, double X)> Pieces, double Width);

public sealed record FittedText(double FontSize, double LinePitch, IReadOnlyList<FittedLine> Lines, bool Overflows);

/// <summary>
/// Breaks translated text into lines that fit the original paragraph's box, shrinking the font until they do.
/// CJK text breaks between any two characters (but never before closing punctuation), other text at spaces.
/// </summary>
public static class PdfTextFitter
{
    private const string NoLineStart = "，。、；：！？）》」』】〕〉…—％,.;:!?)]}%’”·";
    private const string NoLineEnd = "（《「『【〔〈([{‘“";

    /// <param name="measure">Width of a string at font size 1.</param>
    /// <param name="pitchRatio">Distance between baselines as a multiple of the font size (from the original paragraph).</param>
    /// <param name="minScale">The font never shrinks below this share of <paramref name="fontSize"/>.</param>
    /// <param name="firstIndent">The first line starts this far in (a paragraph indent), at any font size.</param>
    public static FittedText Fit(string text, double width, double height, double fontSize, double pitchRatio, Func<string, double> measure,
        bool justify, double minScale = 0.5, double firstIndent = 0) =>
        Fit([new TextRun(text, 0)], width, height, fontSize, pitchRatio, (piece, _) => measure(piece), justify, minScale, firstIndent);

    /// <param name="measure">Width of a string in a style at font size 1.</param>
    public static FittedText Fit(IReadOnlyList<TextRun> runs, double width, double height, double fontSize, double pitchRatio,
        Func<string, int, double> measure, bool justify, double minScale = 0.5, double firstIndent = 0)
    {
        var tokens = Tokenize(runs);
        var widths = new Dictionary<(string, int), double>();
        double Measure(string piece, int style)
        {
            if (!widths.TryGetValue((piece, style), out double value))
                widths[(piece, style)] = value = measure(piece, style);
            return value;
        }

        double min = Math.Max(fontSize * minScale, Math.Min(fontSize, 4));
        for (double size = fontSize; ; size *= 0.95)
        {
            bool last = size * 0.95 < min;
            var lines = Wrap(tokens, width / size, Measure, firstIndent / size);
            double pitch = pitchRatio * size;
            // The first line needs about one font size of height; each further line one pitch.
            double needed = (lines.Count - 1) * pitch + size;
            if (needed <= height + 0.15 * size || last)
            {
                var fitted = lines.Select((line, index) =>
                    Place(line, size, width - (index == 0 ? firstIndent : 0), justify && index < lines.Count - 1, Measure, index == 0 ? firstIndent : 0)).ToList();
                return new FittedText(size, pitch, fitted, needed > height + 0.15 * size);
            }
        }
    }

    /// <summary>A word with the space that preceded it, in parts of one style each.</summary>
    private sealed class Token(bool spaceBefore)
    {
        public bool SpaceBefore { get; } = spaceBefore;
        public List<(string Text, int Style)> Parts { get; } = [];
        public int Length => Parts.Sum(p => p.Text.Length);
        public string Text => string.Concat(Parts.Select(p => p.Text));

        public void Append(char c, int style)
        {
            if (Parts.Count > 0 && Parts[^1].Style == style)
                Parts[^1] = (Parts[^1].Text + c, style);
            else
                Parts.Add((c.ToString(), style));
        }

        public IEnumerable<(char Char, int Style)> Chars() => Parts.SelectMany(p => p.Text.Select(c => (c, p.Style)));

        public double Width(Func<string, int, double> measure) => Parts.Sum(p => measure(p.Text, p.Style));
    }

    private static bool IsCjk(char c) =>
        c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿' or >= '＀' and <= '￯' or >= '　' and <= '〿';

    private static List<Token> Tokenize(IReadOnlyList<TextRun> runs)
    {
        var tokens = new List<Token>();
        Token? word = null;
        bool space = false;

        void Flush()
        {
            if (word is { Length: > 0 })
                tokens.Add(word);
            word = null;
        }

        foreach (var (c, style) in runs.SelectMany(run => run.Text.Select(c => (c, run.Style))))
        {
            if (char.IsWhiteSpace(c))
            {
                Flush();
                space = true;
                continue;
            }
            if (NoLineStart.Contains(c) && !space && (word is not null || tokens.Count > 0))
            {
                // Closing punctuation sticks to what comes before it.
                (word ?? tokens[^1]).Append(c, style);
                continue;
            }
            bool cjk = IsCjk(c);
            // Each CJK character is a token of its own; an opening bracket waits for the character after it.
            if (cjk && word is not null && !word.Text.All(NoLineEnd.Contains))
                Flush();
            if (word is null)
            {
                word = new Token(space);
                space = false;
            }
            word.Append(c, style);
            if (cjk && !NoLineEnd.Contains(c))
                Flush();
        }
        Flush();
        return tokens;
    }

    /// <summary>Greedy line filling in units of the font size; a word wider than the line is broken between characters.</summary>
    private static List<List<Token>> Wrap(List<Token> tokens, double width, Func<string, int, double> measure, double firstIndent)
    {
        var lines = new List<List<Token>>();
        var line = new List<Token>();
        double used = firstIndent; // in font-size units, like width
        foreach (var token in tokens)
        {
            double w = token.Width(measure);
            double extra = line.Count > 0 && token.SpaceBefore ? measure(" ", token.Parts[0].Style) : 0;
            if (line.Count > 0 && used + extra + w > width)
            {
                lines.Add(line);
                line = [];
                used = 0;
                extra = 0;
            }
            if (w > width && line.Count == 0)
            {
                // Break an overlong word (a URL, a long German compound) wherever it has to.
                var piece = new Token(token.SpaceBefore);
                foreach (var (c, style) in token.Chars())
                {
                    if (piece.Length > 0 && piece.Width(measure) + measure(c.ToString(), style) > width)
                    {
                        lines.Add([piece]);
                        piece = new Token(false);
                    }
                    piece.Append(c, style);
                }
                line = [piece];
                used = piece.Width(measure);
                continue;
            }
            line.Add(token);
            used += extra + w;
        }
        if (line.Count > 0)
            lines.Add(line);
        return lines;
    }

    /// <summary>Positions the tokens of a line; a justified line spreads the spare width over its spaces, or between CJK characters.</summary>
    private static FittedLine Place(List<Token> line, double size, double width, bool justify, Func<string, int, double> measure, double indent)
    {
        double Space(Token token) => measure(" ", token.Parts[0].Style) * size;
        double natural = 0;
        for (int i = 0; i < line.Count; i++)
            natural += line[i].Width(measure) * size + (i > 0 && line[i].SpaceBefore ? Space(line[i]) : 0);
        int gaps = line.Count - 1;
        int spaces = line.Skip(1).Count(t => t.SpaceBefore);
        double spare = Math.Max(0, width - natural);
        // Don't stretch a line that is far from full (it would look gappy).
        if (!justify || gaps == 0 || spare > width * 0.25)
            spare = 0;
        double perSpace = spaces > 0 ? spare / spaces : 0;
        double perGap = spaces > 0 ? 0 : spare / Math.Max(1, gaps);

        var pieces = new List<(string, int, double)>();
        var run = new System.Text.StringBuilder();
        int runStyle = int.MinValue;
        double x = indent, runStart = indent;
        void Flush()
        {
            if (run.Length > 0)
                pieces.Add((run.ToString(), runStyle, runStart));
            run.Clear();
        }

        for (int i = 0; i < line.Count; i++)
        {
            var token = line[i];
            if (i > 0)
            {
                double gap = (token.SpaceBefore ? Space(token) + perSpace : 0) + perGap;
                if (spare > 0 || token.Parts[0].Style != runStyle)
                {
                    // Stretched, or in another style: the token is placed on its own.
                    Flush();
                    x += gap;
                    runStart = x;
                }
                else
                {
                    if (token.SpaceBefore)
                        run.Append(' ');
                    x += gap;
                }
            }
            foreach (var (text, style) in token.Parts)
            {
                if (style != runStyle)
                {
                    Flush();
                    runStyle = style;
                    runStart = x;
                }
                run.Append(text);
                x += measure(text, style) * size;
            }
        }
        Flush();
        return new FittedLine(pieces, indent + (spare > 0 ? width : natural));
    }
}
