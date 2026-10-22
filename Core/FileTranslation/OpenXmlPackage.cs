using System.IO;
using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace Translator.Core.FileTranslation;

/// <summary>
/// The zip container of a .docx/.pptx/.xlsx. Parts are found through [Content_Types].xml; every other entry
/// (images, styles, relationships…) is copied to the output byte for byte.
/// </summary>
internal sealed class OpenXmlPackage
{
    private static readonly XNamespace ContentTypesNs = "http://schemas.openxmlformats.org/package/2006/content-types";

    private readonly List<(string Name, DateTimeOffset Time, byte[] Data)> _entries = [];
    private readonly Dictionary<string, string> _contentTypes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, XDocument> _changed = new(StringComparer.OrdinalIgnoreCase);

    private OpenXmlPackage()
    {
    }

    public static OpenXmlPackage Open(string path)
    {
        var package = new OpenXmlPackage();
        try
        {
            using var archive = ZipFile.OpenRead(path);
            foreach (var entry in archive.Entries)
            {
                using var stream = entry.Open();
                using var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                package._entries.Add((entry.FullName, entry.LastWriteTime, buffer.ToArray()));
            }
        }
        catch (InvalidDataException ex)
        {
            // Password-protected Office files are not zip archives at all.
            throw new DocumentException(Loc.T("文件已加密或已损坏，无法打开。如果设置了打开密码，请先在 Office 中取消密码再翻译。",
                "The file is encrypted or damaged. If it has a password, remove it in Office first."), ex);
        }
        package.ReadContentTypes();
        return package;
    }

    private void ReadContentTypes()
    {
        var entry = _entries.FirstOrDefault(e => e.Name.Equals("[Content_Types].xml", StringComparison.OrdinalIgnoreCase));
        if (entry.Data is null)
            throw new DocumentException(Loc.T("不是有效的 Office 文档。", "This isn’t a valid Office document."));
        var types = XDocument.Load(new MemoryStream(entry.Data));
        var defaults = types.Root!.Elements(ContentTypesNs + "Default")
            .ToDictionary(e => ((string?)e.Attribute("Extension") ?? "").ToLowerInvariant(), e => (string?)e.Attribute("ContentType") ?? "");
        foreach (var part in _entries)
        {
            string extension = Path.GetExtension(part.Name).TrimStart('.').ToLowerInvariant();
            if (defaults.TryGetValue(extension, out string? type))
                _contentTypes[part.Name] = type;
        }
        foreach (var element in types.Root.Elements(ContentTypesNs + "Override"))
        {
            string name = ((string?)element.Attribute("PartName") ?? "").TrimStart('/');
            _contentTypes[Uri.UnescapeDataString(name)] = (string?)element.Attribute("ContentType") ?? "";
        }
    }

    /// <summary>Part names with one of the content types, in the order of the types and then in natural order (slide2 before slide10).</summary>
    public List<string> PartsOfType(params string[] contentTypes)
    {
        var result = new List<string>();
        foreach (string type in contentTypes)
        {
            result.AddRange(_entries.Select(e => e.Name)
                .Where(name => _contentTypes.TryGetValue(name, out string? t) && t.Equals(type, StringComparison.OrdinalIgnoreCase))
                .OrderBy(name => name, NaturalComparer.Instance));
        }
        return result;
    }

    public XDocument Load(string part)
    {
        if (_changed.TryGetValue(part, out var changed))
            return changed;
        var entry = _entries.First(e => e.Name.Equals(part, StringComparison.OrdinalIgnoreCase));
        var document = XDocument.Load(new MemoryStream(entry.Data), LoadOptions.PreserveWhitespace);
        _changed[part] = document;
        return document;
    }

    public void Save(Stream output)
    {
        using var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
        foreach (var (name, time, data) in _entries)
        {
            var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
            entry.LastWriteTime = time;
            using var stream = entry.Open();
            if (_changed.TryGetValue(name, out var document))
            {
                using var writer = XmlWriter.Create(stream, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false });
                document.Save(writer);
            }
            else
            {
                stream.Write(data);
            }
        }
    }

    private sealed class NaturalComparer : IComparer<string>
    {
        public static readonly NaturalComparer Instance = new();

        public int Compare(string? a, string? b)
        {
            a ??= "";
            b ??= "";
            int i = 0, j = 0;
            while (i < a.Length && j < b.Length)
            {
                if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
                {
                    int si = i, sj = j;
                    while (i < a.Length && char.IsDigit(a[i])) i++;
                    while (j < b.Length && char.IsDigit(b[j])) j++;
                    int byNumber = long.Parse(a[si..Math.Min(i, si + 18)]).CompareTo(long.Parse(b[sj..Math.Min(j, sj + 18)]));
                    if (byNumber != 0)
                        return byNumber;
                }
                else
                {
                    int byChar = char.ToLowerInvariant(a[i]).CompareTo(char.ToLowerInvariant(b[j]));
                    if (byChar != 0)
                        return byChar;
                    i++;
                    j++;
                }
            }
            return (a.Length - i).CompareTo(b.Length - j);
        }
    }
}
