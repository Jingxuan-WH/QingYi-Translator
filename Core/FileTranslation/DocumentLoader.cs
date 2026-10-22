using System.IO;

namespace Translator.Core.FileTranslation;

/// <summary>Opens a file for translation by its extension.</summary>
public static class DocumentLoader
{
    public static IReadOnlyList<string> Extensions { get; } =
        [".pdf", ".docx", ".pptx", ".xlsx", ".txt", ".md", ".markdown", ".srt", ".docm", ".pptm", ".xlsm"];

    private static readonly Dictionary<string, string> LegacyFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        [".doc"] = ".docx", [".ppt"] = ".pptx", [".xls"] = ".xlsx", [".rtf"] = ".docx", [".wps"] = ".docx",
    };

    public static bool IsSupported(string path) => Extensions.Contains(Path.GetExtension(path).ToLowerInvariant());

    /// <summary>Filter for an open-file dialog.</summary>
    public static string DialogFilter => Loc.T(
        "支持的文件|*.pdf;*.docx;*.pptx;*.xlsx;*.txt;*.md;*.markdown;*.srt;*.docm;*.pptm;*.xlsm|PDF (*.pdf)|*.pdf|Word (*.docx)|*.docx;*.docm|PowerPoint (*.pptx)|*.pptx;*.pptm|Excel (*.xlsx)|*.xlsx;*.xlsm|文本、Markdown、字幕 (*.txt;*.md;*.srt)|*.txt;*.md;*.markdown;*.srt",
        "Supported files|*.pdf;*.docx;*.pptx;*.xlsx;*.txt;*.md;*.markdown;*.srt;*.docm;*.pptm;*.xlsm|PDF (*.pdf)|*.pdf|Word (*.docx)|*.docx;*.docm|PowerPoint (*.pptx)|*.pptx;*.pptm|Excel (*.xlsx)|*.xlsx;*.xlsm|Text, Markdown, subtitles (*.txt;*.md;*.srt)|*.txt;*.md;*.markdown;*.srt");

    /// <summary>Reads the document. Throws <see cref="DocumentException"/> with a message for the user when it can't be translated.</summary>
    public static TranslatableDocument Open(string path)
    {
        string extension = Path.GetExtension(path).ToLowerInvariant();
        if (LegacyFormats.TryGetValue(extension, out string? modern))
            throw new DocumentException(Loc.T($"暂不支持旧版 {extension} 格式，请先在 Office 或 WPS 中另存为 {modern} 再翻译。",
                $"The old {extension} format isn’t supported. Please save it as {modern} in Office first."));
        if (!IsSupported(path))
            throw new DocumentException(Loc.T("暂不支持这种文件。支持 PDF、Word、PowerPoint、Excel、TXT、Markdown 和 SRT 字幕。",
                "This kind of file isn’t supported. Supported: PDF, Word, PowerPoint, Excel, TXT, Markdown and SRT subtitles."));
        if (!File.Exists(path))
            throw new DocumentException(Loc.T("找不到这个文件。", "The file can’t be found."));

        TranslatableDocument document;
        try
        {
            document = extension switch
            {
                ".pdf" => new PdfDocumentFile(path),
                ".txt" => new PlainTextDocument(path),
                ".md" or ".markdown" => new MarkdownDocument(path),
                ".srt" => new SubtitleDocument(path),
                _ => OpenXmlDocument.Open(path),
            };
        }
        catch (DocumentException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new DocumentException(Loc.T($"无法读取文件：{ex.Message}", $"Couldn’t read the file: {ex.Message}"), ex);
        }
        catch (Exception ex)
        {
            Log.Error($"打开文件失败：{path}", ex);
            throw new DocumentException(Loc.T($"无法解析这个文件，它可能已损坏：{ex.Message}", $"Couldn’t read this file; it may be damaged: {ex.Message}"), ex);
        }
        if (document.Segments.Count == 0)
            throw new DocumentException(Loc.T("文件里没有找到需要翻译的文字。", "There’s no text to translate in this file."));
        return document;
    }
}
