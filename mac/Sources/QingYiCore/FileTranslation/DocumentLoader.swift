import Foundation

/// Opens a file for translation by its extension.
public enum DocumentLoader {
    public static let extensions = ["pdf", "docx", "pptx", "xlsx", "txt", "md", "markdown", "srt", "docm", "pptm", "xlsm"]

    private static let legacyFormats = ["doc": "docx", "ppt": "pptx", "xls": "xlsx", "rtf": "docx", "wps": "docx", "pages": "docx", "key": "pptx", "numbers": "xlsx"]

    public static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Reads the document. Throws `DocumentError` with a message for the user when it can't be translated.
    public static func open(_ url: URL) throws -> TranslatableDocument {
        let ext = url.pathExtension.lowercased()
        if let modern = legacyFormats[ext] {
            throw DocumentError(L("暂不支持 .\(ext) 格式，请先在 Office、WPS 或 iWork 中导出为 .\(modern) 再翻译。",
                                  "The .\(ext) format isn’t supported. Please export it as .\(modern) first."))
        }
        guard isSupported(url) else {
            throw DocumentError(L("暂不支持这种文件。支持 PDF、Word、PowerPoint、Excel、TXT、Markdown 和 SRT 字幕。",
                                  "This kind of file isn’t supported. Supported: PDF, Word, PowerPoint, Excel, TXT, Markdown and SRT subtitles."))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentError(L("找不到这个文件。", "The file can’t be found."))
        }

        let document: TranslatableDocument
        do {
            switch ext {
            case "pdf": document = try PdfDocumentFile(url: url)
            case "txt": document = try PlainTextDocument(url: url)
            case "md", "markdown": document = try MarkdownDocument(url: url)
            case "srt": document = try SubtitleDocument(url: url)
            default: document = try OpenXmlDocument.open(url)
            }
        } catch let error as DocumentError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw DocumentError(L("没有权限读取这个文件。", "There’s no permission to read this file."))
        } catch {
            Log.error("打开文件失败：\(url.path)", error)
            throw DocumentError(L("无法解析这个文件，它可能已损坏：\(error.localizedDescription)",
                                  "Couldn’t read this file; it may be damaged: \(error.localizedDescription)"))
        }
        if document.segments.isEmpty {
            throw DocumentError(L("文件里没有找到需要翻译的文字。", "There’s no text to translate in this file."))
        }
        return document
    }
}
