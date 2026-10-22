import Foundation

enum OfficeNs {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let x = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let m = "http://schemas.openxmlformats.org/officeDocument/2006/math"
    static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
}

private func w(_ name: String) -> QName { QName(OfficeNs.w, name) }
private func a(_ name: String) -> QName { QName(OfficeNs.a, name) }
private func p(_ name: String) -> QName { QName(OfficeNs.p, name) }
private func x(_ name: String) -> QName { QName(OfficeNs.x, name) }

/// Word, PowerPoint and Excel files. The text is replaced inside the existing XML, so styles, tables, images,
/// headers and footers, footnotes and text boxes are left exactly as they were.
public class OpenXmlDocument: TranslatableDocument {
    static let wordDialect = InlineDialect(
        run: w("r"), runProperties: w("rPr"), text: w("t"), preserveSpace: true,
        containers: [w("hyperlink"), w("smartTag"), w("customXml"), w("sdt"), w("ins"), w("moveTo"), w("dir"), w("bdo")],
        containerContent: [w("sdt"): w("sdtContent")],
        atoms: [QName(OfficeNs.m, "oMath"), QName(OfficeNs.m, "oMathPara"), w("fldSimple"), QName(OfficeNs.mc, "AlternateContent")],
        disposable: [w("lastRenderedPageBreak")],
        fieldChar: w("fldChar"), fieldNamespace: OfficeNs.w,
        removableWhenEmpty: [w("hyperlink"), w("smartTag"), w("ins"), w("moveTo")],
        // Language, proofing and complex-script variants don't change how Latin or CJK text looks.
        styleKey: { InlineParagraph.propertiesKey($0, dropElements: ["lang", "noProof", "szCs", "bCs", "iCs", "rtl", "cs"],
                                                  dropAttributes: ["hint", "rsidRPr"]) })

    static let drawingDialect = InlineDialect(
        run: a("r"), runProperties: a("rPr"), text: a("t"),
        atoms: [a("br"), a("fld"), QName(OfficeNs.mc, "AlternateContent")],
        styleKey: { InlineParagraph.propertiesKey($0, dropElements: [],
                                                  dropAttributes: ["lang", "altLang", "dirty", "err", "smtClean", "smtId", "noProof", "bmk"]) })

    static let spreadsheetDialect = InlineDialect(
        run: x("r"), runProperties: x("rPr"), text: x("t"), preserveSpace: true,
        styleKey: { InlineParagraph.propertiesKey($0, dropElements: [], dropAttributes: []) })

    let package: OpenXmlPackage
    private var paragraphs: [(paragraph: InlineParagraph, segment: Int)] = []

    init(url: URL) throws {
        package = try OpenXmlPackage(url: url)
        super.init(sourceURL: url)
    }

    /// Adds the paragraphs of one part; returns the segments that were created, in order.
    @discardableResult
    func addParagraphs(_ elements: [XMLElement], dialect: InlineDialect,
                       role: (XMLElement) -> SegmentRole) -> [(element: XMLElement, paragraph: InlineParagraph, segment: DocumentSegment)] {
        var added: [(element: XMLElement, paragraph: InlineParagraph, segment: DocumentSegment)] = []
        var fieldDepth = 0
        for element in elements {
            let paragraph = InlineParagraph(element, dialect: dialect, fieldDepth: &fieldDepth)
            guard paragraph.hasWords else { continue }
            let segment = addSegment(paragraph.pieces(), role: role(element))
            paragraphs.append((paragraph, segment.id))
            added.append((element, paragraph, segment))
        }
        return added
    }

    /// Called after the translations are written and before the file is saved.
    func afterApply(_ translations: [Int: String]) {}

    public override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        for (paragraph, segment) in paragraphs {
            if let translation = translations[segment] {
                paragraph.apply(segments[segment].text, translation)
            }
        }
        afterApply(translations)
        try TranslatableDocument.writeAtomically(to: url) { try package.save(to: $0) }
    }

    public static func open(_ url: URL) throws -> OpenXmlDocument {
        switch url.pathExtension.lowercased() {
        case "docx", "docm", "dotx": return try WordDocument(url: url)
        case "pptx", "pptm", "ppsx": return try PresentationDocument(url: url)
        default: return try SpreadsheetDocument(url: url)
        }
    }
}

/// .docx: body, headers, footers, footnotes and endnotes, including text boxes and tables.
public final class WordDocument: OpenXmlDocument {
    private static let ns = "application/vnd.openxmlformats-officedocument.wordprocessingml."

    public override init(url: URL) throws {
        try super.init(url: url)
        let ns = WordDocument.ns
        let mainParts = package.parts(ofType: ns + "document.main+xml", "application/vnd.ms-word.document.macroEnabled.main+xml",
                                      ns + "template.main+xml", "application/vnd.ms-word.template.macroEnabledTemplate.main+xml")
        guard let main = mainParts.first else {
            throw DocumentError(L("这不是有效的 Word 文档。", "This isn’t a valid Word document."))
        }
        let styles = try readStyles()

        func roleOf(_ paragraph: XMLElement) -> SegmentRole {
            let properties = paragraph.child(w("pPr"))
            let styleId = properties?.child(w("pStyle"))?.attributeValue("val", ns: OfficeNs.w)
            let style = styleId.flatMap { styles[$0] }
            if style?.name == "title" {
                return .title
            }
            if style?.name?.hasPrefix("heading") == true || style?.outline == true
                || (properties?.child(w("outlineLvl")).map { $0.attributeValue("val", ns: OfficeNs.w) != "9" } ?? false) {
                return .heading
            }
            return .body
        }

        for part in [main] + package.parts(ofType: ns + "header+xml", ns + "footer+xml", ns + "footnotes+xml", ns + "endnotes+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            let added = addParagraphs(root.descendants(w("p")), dialect: OpenXmlDocument.wordDialect, role: roleOf)
            guard part == main else { continue }
            // Reference lists usually stay in the original language; they run from the "References" heading to the next heading.
            var inReferences = false
            for item in added {
                if ReferenceSection.isHeading(item.paragraph.plainText) {
                    inReferences = true
                    continue
                }
                if inReferences && (item.segment.role == .heading || item.segment.role == .title) {
                    inReferences = false
                }
                item.segment.isReference = inReferences
            }
        }
    }

    /// Style id → lower-case style name and whether it is an outline (heading) level.
    private func readStyles() throws -> [String: (name: String?, outline: Bool)] {
        var styles: [String: (name: String?, outline: Bool)] = [:]
        for part in package.parts(ofType: WordDocument.ns + "styles+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            for style in root.children(w("style")) {
                guard let id = style.attributeValue("styleId", ns: OfficeNs.w) else { continue }
                let name = style.child(w("name"))?.attributeValue("val", ns: OfficeNs.w)?.lowercased()
                let level = style.child(w("pPr"))?.child(w("outlineLvl"))
                styles[id] = (name, level != nil && level?.attributeValue("val", ns: OfficeNs.w) != "9")
            }
        }
        return styles
    }
}

/// .pptx: slides and speaker notes, including tables and grouped shapes.
public final class PresentationDocument: OpenXmlDocument {
    private static let ns = "application/vnd.openxmlformats-officedocument.presentationml."

    private var slideParagraphs: [(paragraph: XMLElement, segment: DocumentSegment)] = []

    public override init(url: URL) throws {
        try super.init(url: url)
        let slides = package.parts(ofType: PresentationDocument.ns + "slide+xml")
        if slides.isEmpty {
            throw DocumentError(L("演示文稿里没有幻灯片。", "The presentation has no slides."))
        }
        for (index, part) in slides.enumerated() {
            guard let root = try package.load(part).rootElement() else { continue }
            let added = addParagraphs(root.descendants(a("p")), dialect: OpenXmlDocument.drawingDialect) {
                PresentationDocument.roleOf($0, firstSlide: index == 0)
            }
            slideParagraphs += added.map { ($0.element, $0.segment) }
        }
        for part in package.parts(ofType: PresentationDocument.ns + "notesSlide+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            addParagraphs(root.descendants(a("p")), dialect: OpenXmlDocument.drawingDialect) { _ in .body }
        }
    }

    private static func roleOf(_ paragraph: XMLElement, firstSlide: Bool) -> SegmentRole {
        if !paragraph.ancestors(a("tbl")).isEmpty {
            return .other
        }
        let shape = paragraph.ancestors(p("sp")).first
        let type = shape?.child(p("nvSpPr"))?.child(p("nvPr"))?.child(p("ph"))?.attributeValue("type")
        switch type {
        case "ctrTitle" where firstSlide: return .title
        case "title", "ctrTitle": return .heading
        default: return .body
        }
    }

    /// Text that got longer (e.g. Chinese → English) would overflow its box. PowerPoint applies a stored
    /// "shrink text on overflow" scale when it opens the file, so text boxes get a scale that makes room.
    override func afterApply(_ translations: [Int: String]) {
        var bodies: [(body: XMLElement, items: [DocumentSegment])] = []
        for (paragraph, segment) in slideParagraphs {
            guard let body = paragraph.parent as? XMLElement else { continue }
            if let index = bodies.firstIndex(where: { $0.body === body }) {
                bodies[index].items.append(segment)
            } else {
                bodies.append((body, [segment]))
            }
        }
        for (body, items) in bodies where body.isNamed(p("txBody")) {
            var before = 0, after = 0
            for segment in items {
                before += InlineParagraph.displayWidth(segment.plainText)
                after += InlineParagraph.displayWidth(translations[segment.id].map(TaggedText.stripTags) ?? segment.plainText)
            }
            let ratio = before == 0 ? 1 : Double(after) / Double(before)
            guard ratio > 1.15, let properties = body.child(a("bodyPr")), properties.child(a("spAutoFit")) == nil else { continue }
            let existing = properties.child(a("normAutofit"))
            var scale = existing.flatMap { $0.attributeValue("fontScale") }.flatMap { Double($0) }.map { $0 / 100000 } ?? 1
            scale = min(max(scale / ratio.squareRoot(), 0.25), 1)
            existing?.detach()
            properties.child(a("noAutofit"))?.detach()
            let prefix = properties.prefix.map { $0.isEmpty ? "" : $0 + ":" } ?? "a:"
            let autofit = XMLElement(name: prefix + "normAutofit", uri: OfficeNs.a)
            autofit.setAttributeValue("fontScale", String(Int((scale * 100000 / 2500).rounded()) * 2500))
            if scale < 0.8 {
                autofit.setAttributeValue("lnSpcReduction", "10000")
            }
            // Schema order: prstTxWarp comes before the autofit element.
            if let warp = properties.child(a("prstTxWarp")) {
                warp.insertAfter(autofit)
            } else {
                properties.insertChild(autofit, at: 0)
            }
        }
    }
}

/// .xlsx: text cells (shared and inline strings) and text boxes. Numbers, dates and formulas are not touched.
public final class SpreadsheetDocument: OpenXmlDocument {
    private static let ns = "application/vnd.openxmlformats-officedocument.spreadsheetml."

    public override init(url: URL) throws {
        try super.init(url: url)
        for part in package.parts(ofType: SpreadsheetDocument.ns + "sharedStrings+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            addParagraphs(root.children(x("si")), dialect: OpenXmlDocument.spreadsheetDialect) { _ in .body }
        }
        for part in package.parts(ofType: SpreadsheetDocument.ns + "worksheet+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            let inline = root.descendants(x("c"))
                .filter { $0.attributeValue("t") == "inlineStr" && $0.child(x("f")) == nil }
                .compactMap { $0.child(x("is")) }
            addParagraphs(inline, dialect: OpenXmlDocument.spreadsheetDialect) { _ in .body }
        }
        for part in package.parts(ofType: "application/vnd.openxmlformats-officedocument.drawing+xml") {
            guard let root = try package.load(part).rootElement() else { continue }
            addParagraphs(root.descendants(a("p")), dialect: OpenXmlDocument.drawingDialect) { _ in .body }
        }
    }
}
