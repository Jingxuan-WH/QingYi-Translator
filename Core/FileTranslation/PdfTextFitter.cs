namespace Translator.Core.FileTranslation;

/// <summary>A line of fitted text: its pieces and where each starts, relative to the line's left edge.</summary>
public sealed record FittedLine(IReadOnlyList<(string Text, double X)> Pieces, double Width);

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
        bool justify, double minScale = 0.5, double firstIndent = 0)
    {
        var tokens = Tokenize(text);
        var widths = new Dictionary<string, double>();
        double Measure(string piece)
        {
            if (!widths.TryGetValue(piece, out double value))
                widths[piece] = value = measure(piece);
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

    /// <summary>A word with the space that preceded it.</summary>
    private readonly record struct Token(string Text, bool SpaceBefore);

    private static bool IsCjk(char c) =>
        c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿' or >= '＀' and <= '￯' or >= '　' and <= '〿';

    private static List<Token> Tokenize(string text)
    {
        var tokens = new List<Token>();
        var word = new System.Text.StringBuilder();
        bool space = false, wordSpace = false;

        void Flush()
        {
            if (word.Length > 0)
                tokens.Add(new Token(word.ToString(), wordSpace));
            word.Clear();
        }

        foreach (char c in text)
        {
            if (char.IsWhiteSpace(c))
            {
                Flush();
                space = true;
                continue;
            }
            if (NoLineStart.Contains(c) && !space && (word.Length > 0 || tokens.Count > 0))
            {
                // Closing punctuation sticks to what comes before it.
                if (word.Length > 0)
                    word.Append(c);
                else
                    tokens[^1] = tokens[^1] with { Text = tokens[^1].Text + c };
                continue;
            }
            bool cjk = IsCjk(c);
            // Each CJK character is a token of its own; an opening bracket waits for the character after it.
            if (cjk && word.Length > 0 && !word.ToString().All(NoLineEnd.Contains))
                Flush();
            if (word.Length == 0)
            {
                wordSpace = space;
                space = false;
            }
            word.Append(c);
            if (cjk && !NoLineEnd.Contains(c))
                Flush();
        }
        Flush();
        return tokens;
    }

    /// <summary>Greedy line filling in units of the font size; a word wider than the line is broken between characters.</summary>
    private static List<List<Token>> Wrap(List<Token> tokens, double width, Func<string, double> measure, double firstIndent)
    {
        var lines = new List<List<Token>>();
        var line = new List<Token>();
        double space = measure(" ");
        double used = firstIndent; // in font-size units, like width
        foreach (var token in tokens)
        {
            double w = measure(token.Text);
            double extra = line.Count > 0 && token.SpaceBefore ? space : 0;
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
                var piece = new System.Text.StringBuilder();
                bool first = true;
                foreach (char c in token.Text)
                {
                    if (piece.Length > 0 && measure(piece.ToString() + c) > width)
                    {
                        lines.Add([new Token(piece.ToString(), first && token.SpaceBefore)]);
                        first = false;
                        piece.Clear();
                    }
                    piece.Append(c);
                }
                line = [new Token(piece.ToString(), false)];
                used = measure(piece.ToString());
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
    private static FittedLine Place(List<Token> line, double size, double width, bool justify, Func<string, double> measure, double indent)
    {
        double space = measure(" ") * size;
        double natural = 0;
        for (int i = 0; i < line.Count; i++)
            natural += measure(line[i].Text) * size + (i > 0 && line[i].SpaceBefore ? space : 0);
        int gaps = line.Count - 1;
        int spaces = line.Skip(1).Count(t => t.SpaceBefore);
        double spare = Math.Max(0, width - natural);
        // Don't stretch a line that is far from full (it would look gappy).
        if (!justify || gaps == 0 || spare > width * 0.25)
            spare = 0;
        double perSpace = spaces > 0 ? spare / spaces : 0;
        double perGap = spaces > 0 ? 0 : spare / Math.Max(1, gaps);

        var pieces = new List<(string, double)>();
        var run = new System.Text.StringBuilder();
        double x = indent, runStart = indent;
        for (int i = 0; i < line.Count; i++)
        {
            var token = line[i];
            if (i > 0)
            {
                double gap = (token.SpaceBefore ? space + perSpace : 0) + perGap;
                if (spare > 0)
                {
                    // Stretched: every token is placed on its own.
                    pieces.Add((run.ToString(), runStart));
                    run.Clear();
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
            run.Append(token.Text);
            x += measure(token.Text) * size;
        }
        if (run.Length > 0)
            pieces.Add((run.ToString(), runStart));
        return new FittedLine(pieces, indent + (spare > 0 ? width : natural));
    }
}
