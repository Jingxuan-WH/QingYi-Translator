using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;

namespace Translator.Core.FileTranslation;

/// <summary>
/// Takes the original text out of a page's content stream where it was translated, so the translated PDF can be
/// searched and copied without the old text showing up underneath. Each text-drawing operator is judged by where
/// it starts drawing (tracked through the text and transformation matrices); graphics are never touched.
/// Text inside form XObjects can't be reached this way; it stays covered instead.
/// </summary>
internal static class PdfTextRemover
{
    /// <summary>
    /// Removes the text operators that start where <paramref name="remove"/> says (user space). Returns the start
    /// points of the removed text, or null when the page wasn't changed (no match, or content it can't safely rewrite).
    /// </summary>
    public static List<(double X, double Y)>? Remove(PdfPage page, Func<double, double, bool> remove)
    {
        CSequence content;
        try
        {
            content = ContentReader.ReadContent(page);
        }
        catch (Exception ex)
        {
            Log.Info($"无法解析 PDF 页面内容，改为遮盖原文：{ex.Message}");
            return null;
        }
        // Inline images carry binary data that a rewrite could damage.
        if (content.OfType<COperator>().Any(op => op.OpCode.OpCodeName is OpCodeName.BI or OpCodeName.ID or OpCodeName.EI))
            return null;

        var removed = new List<(double, double)>();
        var result = new CSequence();
        var states = new Stack<(Matrix Ctm, double Leading)>();
        var ctm = Matrix.Identity;
        double leading = 0;
        Matrix line = Matrix.Identity, text = Matrix.Identity;

        foreach (var item in content)
        {
            if (item is not COperator op)
            {
                result.Add(item);
                continue;
            }
            var operands = op.Operands;
            switch (op.OpCode.OpCodeName)
            {
                case OpCodeName.q:
                    states.Push((ctm, leading));
                    break;
                case OpCodeName.Q:
                    if (states.Count > 0)
                        (ctm, leading) = states.Pop();
                    break;
                case OpCodeName.cm when operands.Count == 6:
                    ctm = Matrix.From(operands) * ctm;
                    break;
                case OpCodeName.BT:
                    line = text = Matrix.Identity;
                    break;
                case OpCodeName.Tm when operands.Count == 6:
                    line = text = Matrix.From(operands);
                    break;
                case OpCodeName.Td when operands.Count == 2:
                    line = text = Matrix.Translate(Number(operands[0]), Number(operands[1])) * line;
                    break;
                case OpCodeName.TD when operands.Count == 2:
                    leading = -Number(operands[1]);
                    line = text = Matrix.Translate(Number(operands[0]), Number(operands[1])) * line;
                    break;
                case OpCodeName.TL when operands.Count == 1:
                    leading = Number(operands[0]);
                    break;
                case OpCodeName.Tx: // T*
                    line = text = Matrix.Translate(0, -leading) * line;
                    break;
                case OpCodeName.Tj or OpCodeName.TJ:
                {
                    var (x, y) = (text * ctm).Origin;
                    if (remove(x, y))
                    {
                        removed.Add((x, y));
                        continue;
                    }
                    break;
                }
                case OpCodeName.QuoteSingle or OpCodeName.QuoteDouble:
                {
                    // ' and " move to the next line before drawing; keep the move (and the spacing " sets).
                    line = text = Matrix.Translate(0, -leading) * line;
                    var (x, y) = (text * ctm).Origin;
                    if (remove(x, y))
                    {
                        removed.Add((x, y));
                        if (op.OpCode.OpCodeName == OpCodeName.QuoteDouble && operands.Count == 3)
                        {
                            result.Add(Operator("Tw", operands[0]));
                            result.Add(Operator("Tc", operands[1]));
                        }
                        result.Add(Operator("T*"));
                        continue;
                    }
                    break;
                }
            }
            result.Add(op);
        }

        if (removed.Count == 0)
            return null;
        page.Contents.ReplaceContent(result);
        return removed;
    }

    private static COperator Operator(string name, params CObject[] operands)
    {
        var op = OpCodes.OperatorFromName(name);
        foreach (var operand in operands)
            op.Operands.Add(operand);
        return op;
    }

    private static double Number(CObject value) => value switch
    {
        CInteger integer => integer.Value,
        CReal real => real.Value,
        _ => 0,
    };

    /// <summary>A 2D affine transform in PDF's row-vector convention: [a b c d e f].</summary>
    private readonly record struct Matrix(double A, double B, double C, double D, double E, double F)
    {
        public static readonly Matrix Identity = new(1, 0, 0, 1, 0, 0);

        public static Matrix Translate(double x, double y) => new(1, 0, 0, 1, x, y);

        public static Matrix From(CSequence operands) =>
            new(Number(operands[0]), Number(operands[1]), Number(operands[2]), Number(operands[3]), Number(operands[4]), Number(operands[5]));

        public (double X, double Y) Origin => (E, F);

        public static Matrix operator *(Matrix m, Matrix n) => new(
            m.A * n.A + m.B * n.C, m.A * n.B + m.B * n.D,
            m.C * n.A + m.D * n.C, m.C * n.B + m.D * n.D,
            m.E * n.A + m.F * n.C + n.E, m.E * n.B + m.F * n.D + n.F);
    }
}
