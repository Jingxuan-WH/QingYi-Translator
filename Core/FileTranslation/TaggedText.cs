using System.Text;
using System.Text.RegularExpressions;

namespace Translator.Core.FileTranslation;

/// <summary>A piece of a paragraph: text in one of the paragraph's formats, or an object that must stay as it is.</summary>
/// <param name="Style">Index of the format among the paragraph's formats (text pieces).</param>
/// <param name="Atom">Index of the object among the paragraph's objects (formulas, images, footnote marks…); -1 for text.</param>
public readonly record struct InlinePiece(string Text, int Style, int Atom = -1)
{
    public bool IsAtom => Atom >= 0;

    public static InlinePiece Of(string text, int style) => new(text, style);

    public static InlinePiece Object(int atom, string text = "") => new(text, -1, atom);
}

/// <summary>
/// A paragraph sent to the model with its formatting as inline tags: text in a format other than the paragraph's
/// main one is wrapped as &lt;1&gt;…&lt;/1&gt; (one number per format), and objects such as formulas or images
/// become &lt;2/&gt;. The model translates the text and keeps the tags, so the formatting can be put back.
/// </summary>
public sealed class TaggedText
{
    private static readonly Regex TagPattern = new(@"<(/?)(\d{1,3})(\s*/)?>", RegexOptions.CultureInvariant);

    private readonly Dictionary<int, int> _styleOfTag = [];
    private readonly Dictionary<int, int> _atomOfTag = [];

    private TaggedText(int baseStyle) => BaseStyle = baseStyle;

    /// <summary>What is sent for translation.</summary>
    public string Text { get; private set; } = "";

    /// <summary>The paragraph's main format; untagged text in the translation gets it.</summary>
    public int BaseStyle { get; }

    public bool HasTags => _styleOfTag.Count > 0 || _atomOfTag.Count > 0;

    /// <summary>Builds the tagged text. The format with the most characters stays untagged, which keeps the tags few.</summary>
    public static TaggedText Build(IReadOnlyList<InlinePiece> pieces)
    {
        var lengths = new Dictionary<int, int>();
        foreach (var piece in pieces)
        {
            if (!piece.IsAtom)
                lengths[piece.Style] = lengths.GetValueOrDefault(piece.Style) + piece.Text.Trim().Length;
        }
        int baseStyle = 0, best = -1;
        foreach (var piece in pieces)
        {
            // Ties go to the format that comes first.
            if (!piece.IsAtom && lengths[piece.Style] > best)
            {
                best = lengths[piece.Style];
                baseStyle = piece.Style;
            }
        }

        var result = new TaggedText(baseStyle);
        var tagOfStyle = new Dictionary<int, int>();
        var tagOfAtom = new Dictionary<int, int>();
        var text = new StringBuilder();
        int nextTag = 1;
        foreach (var piece in pieces)
        {
            if (piece.IsAtom)
            {
                if (!tagOfAtom.TryGetValue(piece.Atom, out int tag))
                {
                    tag = nextTag++;
                    tagOfAtom[piece.Atom] = tag;
                    result._atomOfTag[tag] = piece.Atom;
                }
                text.Append('<').Append(tag).Append("/>");
            }
            else if (piece.Style == baseStyle || piece.Text.Trim().Length == 0)
            {
                // Whitespace in another format isn't worth a tag.
                text.Append(piece.Text);
            }
            else
            {
                if (!tagOfStyle.TryGetValue(piece.Style, out int tag))
                {
                    tag = nextTag++;
                    tagOfStyle[piece.Style] = tag;
                    result._styleOfTag[tag] = piece.Style;
                }
                // Spaces stay outside the tags, so the model doesn't drop or move them.
                string value = piece.Text;
                int lead = value.Length - value.TrimStart().Length;
                int trail = value.Length - value.TrimEnd().Length;
                text.Append(value, 0, lead).Append('<').Append(tag).Append('>').Append(value.Trim())
                    .Append("</").Append(tag).Append('>').Append(value, value.Length - trail, trail);
            }
        }
        result.Text = text.ToString();
        return result;
    }

    /// <summary>
    /// Reads a translation back into pieces. Unknown, unbalanced or misplaced tags are dropped rather than
    /// failing: the text then simply gets the main format. Adjacent text in the same format is merged.
    /// </summary>
    public List<InlinePiece> Parse(string translation)
    {
        var pieces = new List<InlinePiece>();
        var open = new List<int>(); // styles of the tags currently open, innermost last
        int position = 0;

        void AddText(string text)
        {
            if (text.Length == 0)
                return;
            int style = open.Count > 0 ? open[^1] : BaseStyle;
            if (pieces.Count > 0 && !pieces[^1].IsAtom && pieces[^1].Style == style)
                pieces[^1] = InlinePiece.Of(pieces[^1].Text + text, style);
            else
                pieces.Add(InlinePiece.Of(text, style));
        }

        foreach (Match match in TagPattern.Matches(translation))
        {
            int tag = int.Parse(match.Groups[2].Value);
            bool closing = match.Groups[1].Length > 0;
            bool selfClosing = match.Groups[3].Success;
            bool known = _styleOfTag.ContainsKey(tag) || _atomOfTag.ContainsKey(tag);
            if (!known)
                continue; // e.g. "<5>" that was part of the text itself: leave it in place

            AddText(translation[position..match.Index]);
            position = match.Index + match.Length;
            if (_atomOfTag.TryGetValue(tag, out int atom))
            {
                if (!closing)
                    pieces.Add(InlinePiece.Object(atom));
            }
            else if (!selfClosing)
            {
                int style = _styleOfTag[tag];
                if (!closing)
                {
                    open.Add(style);
                }
                else
                {
                    int index = open.LastIndexOf(style);
                    if (index >= 0)
                        open.RemoveRange(index, open.Count - index);
                }
            }
        }
        AddText(translation[position..]);
        return pieces;
    }

    /// <summary>The text without any tags, e.g. for the domain sample or for formats that can't hold formatting.</summary>
    public static string StripTags(string text) => TagPattern.Replace(text, "");
}
