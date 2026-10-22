import Foundation

/// The element names of one Office markup language (WordprocessingML, DrawingML or SpreadsheetML).
struct InlineDialect {
    var run: QName
    var runProperties: QName
    var text: QName
    /// Whether `text` needs xml:space="preserve" to keep leading and trailing spaces.
    var preserveSpace = false
    /// Elements whose runs belong to the paragraph's text, e.g. hyperlinks. They become part of the format.
    var containers: Set<QName> = []
    /// For containers whose runs sit in a child (w:sdt → w:sdtContent).
    var containerContent: [QName: QName] = [:]
    /// Paragraph-level elements that are objects, e.g. formulas and line breaks.
    var atoms: Set<QName> = []
    /// Run children that are only caches and can be dropped (w:lastRenderedPageBreak).
    var disposable: Set<QName> = []
    /// Complex field markers; everything between begin and end stays as one object.
    var fieldChar: QName?
    var fieldNamespace: String?
    /// Containers that may be removed once empty.
    var removableWhenEmpty: Set<QName> = []
    /// The run properties as a comparable key, without attributes that don't change the look (language, proofing).
    var styleKey: (XMLElement?) -> String
}

/// One paragraph of an Office document prepared for translation. Runs are split so each holds one piece of text
/// or one object, runs that look the same are merged, and the result is offered as tagged text. The translation is
/// written back by filling the existing runs in order and cloning a run only when the translation needs a format
/// in a place the original didn't have it, so everything that isn't text (images, formulas, footnote marks,
/// fields, bookmarks) stays in the paragraph.
final class InlineParagraph {
    private struct Slot {
        var nodes: [XMLElement] // a text run, or the element(s) of an object
        var style = -1          // -1 for objects
        var atom = -1
        var isText: Bool { style >= 0 }
        var run: XMLElement { nodes[0] }
    }

    private let paragraph: XMLElement
    private let dialect: InlineDialect
    private var slots: [Slot] = []
    private var styleKeys: [String] = []
    private(set) var atomCount = 0

    /// `fieldDepth`: complex fields can span paragraphs; the depth carries over from the previous paragraph.
    init(_ paragraph: XMLElement, dialect: InlineDialect, fieldDepth: inout Int) {
        self.paragraph = paragraph
        self.dialect = dialect
        var items: [(node: XMLElement, style: String?, field: [XMLElement]?)] = [] // style nil: object
        var field: [XMLElement] = []
        var depth = fieldDepth

        func closeField() {
            if !field.isEmpty {
                items.append((field[0], nil, field))
            }
            field = []
        }

        func walk(_ parent: XMLElement, _ chain: String) {
            for child in parent.childElements {
                if child.isNamed(dialect.run) || (child.isNamed(dialect.text) && parent === paragraph) {
                    for run in child.isNamed(dialect.run) ? splitRun(child) : [child] {
                        let content: XMLElement? = run.isNamed(dialect.text)
                            ? run : run.childElements.first(where: { !$0.isNamed(dialect.runProperties) })
                        guard let content else { continue }
                        if let fieldChar = dialect.fieldChar, content.isNamed(fieldChar) {
                            let type = content.attributeValue("fldCharType", ns: dialect.fieldNamespace) ?? ""
                            if type == "begin" {
                                depth += 1
                            }
                            field.append(run)
                            if type == "end" {
                                depth -= 1
                                if depth <= 0 {
                                    depth = 0
                                    closeField()
                                }
                            }
                            continue
                        }
                        if depth > 0 {
                            field.append(run)
                            continue
                        }
                        if content.isNamed(dialect.text) {
                            items.append((run, chain + "|" + dialect.styleKey(run.child(dialect.runProperties)), nil))
                        } else {
                            items.append((run, nil, nil))
                        }
                    }
                } else if dialect.containers.contains(child.qname) {
                    let inner = dialect.containerContent[child.qname].flatMap { child.child($0) } ?? child
                    walk(inner, chain + "/" + InlineParagraph.containerKey(child))
                } else if dialect.atoms.contains(child.qname) {
                    if depth > 0 {
                        field.append(child)
                    } else {
                        items.append((child, nil, nil))
                    }
                }
                // Anything else (paragraph properties, bookmarks, comment ranges, deletions…) stays where it is.
            }
        }

        walk(paragraph, "")
        // A field still open at the end continues in the next paragraph (e.g. a table of contents).
        closeField()
        fieldDepth = depth

        // Merge neighbouring runs that look the same, so "Hel" + "lo" (split by spell checking or editing) is one piece.
        for item in items {
            guard let style = item.style else {
                slots.append(Slot(nodes: item.field ?? [item.node], atom: atomCount))
                atomCount += 1
                continue
            }
            if let last = slots.last, last.isText, styleKeys[last.style] == style, last.run.parent === item.node.parent {
                setText(last.run, getText(last.run) + getText(item.node))
                item.node.detach()
                continue
            }
            var index = styleKeys.firstIndex(of: style) ?? -1
            if index < 0 {
                index = styleKeys.count
                styleKeys.append(style)
            }
            slots.append(Slot(nodes: [item.node], style: index))
        }
    }

    var hasWords: Bool { slots.contains { $0.isText && TranslatableDocument.hasWords(getText($0.run)) } }

    var plainText: String { slots.filter(\.isText).map { getText($0.run) }.joined() }

    func pieces() -> [InlinePiece] {
        slots.map { $0.isText ? .of(getText($0.run), $0.style) : .object($0.atom) }
    }

    private static func containerKey(_ container: XMLElement) -> String {
        let attributes = (container.attributes ?? []).map { " \($0.localName ?? $0.name ?? "")=\($0.stringValue ?? "")" }.sorted()
        return (container.localName ?? "") + attributes.joined()
    }

    /// Gives every text or object its own run (with a copy of the run properties); returns the runs in order.
    private func splitRun(_ run: XMLElement) -> [XMLElement] {
        for cache in run.childElements where dialect.disposable.contains(cache.qname) {
            cache.detach()
        }
        let contents = run.childElements.filter { !$0.isNamed(dialect.runProperties) }
        guard contents.count > 1 else { return [run] }
        let properties = run.child(dialect.runProperties)
        var runs: [XMLElement] = []
        for content in contents {
            content.detach()
            let single = XMLElement(name: run.name ?? "r", uri: run.uri)
            for attribute in run.attributes ?? [] {
                single.addAttribute(attribute.copy() as! XMLNode)
            }
            if let properties {
                single.addChild(properties.deepCopy())
            }
            single.addChild(content)
            run.insertBefore(single)
            runs.append(single)
        }
        run.detach()
        return runs
    }

    private func textElement(_ run: XMLElement) -> XMLElement? { run.isNamed(dialect.text) ? run : run.child(dialect.text) }

    private func getText(_ run: XMLElement) -> String { textElement(run)?.stringValue ?? "" }

    private func setText(_ run: XMLElement, _ text: String) {
        guard let element = textElement(run) else { return }
        element.stringValue = text
        if dialect.preserveSpace {
            let needed = text.first?.isWhitespace == true || text.last?.isWhitespace == true
            element.setAttributeValue("xml:space", needed ? "preserve" : nil)
        }
    }

    /// The direct child of the paragraph that holds `node`.
    private func topLevel(_ node: XMLElement) -> XMLElement {
        var current = node
        while let parent = current.parent as? XMLElement, parent !== paragraph {
            current = parent
        }
        return current
    }

    /// Writes the translation (tagged text) into the paragraph.
    func apply(_ tagged: TaggedText, _ translation: String) {
        let flat = translation.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let pieces = tagged.parse(flat)
        var used = [Bool](repeating: false, count: slots.count)
        var cursor = -1
        var anchor: XMLElement? // the last node written, at any depth

        func insertAfterAnchor(_ node: XMLElement) {
            if let current = anchor {
                let top = topLevel(current)
                top.insertAfter(node)
                // Slots still inside that container now come before the insertion point.
                if cursor + 1 < slots.count {
                    for i in (cursor + 1)..<slots.count where slots[i].nodes.contains(where: { $0.parent != nil && topLevel($0) === top }) {
                        cursor = i
                    }
                }
            } else if let first = slots.first {
                topLevel(first.nodes[0]).insertBefore(node)
            } else {
                paragraph.addChild(node)
            }
            anchor = node
        }

        for piece in pieces {
            if !piece.isAtom {
                guard !piece.text.isEmpty else { continue }
                var next = -1
                if cursor + 1 < slots.count {
                    for i in (cursor + 1)..<slots.count where slots[i].style == piece.style && !used[i] {
                        next = i
                        break
                    }
                }
                if next >= 0 {
                    setText(slots[next].run, piece.text)
                    used[next] = true
                    cursor = next
                    anchor = slots[next].run
                } else if let template = slots.first(where: { $0.style == piece.style }) {
                    let clone = template.run.deepCopy()
                    setText(clone, piece.text)
                    insertAfterAnchor(clone)
                }
            } else {
                guard let index = slots.firstIndex(where: { $0.atom == piece.atom }), !used[index] else { continue }
                used[index] = true
                if index > cursor {
                    cursor = index
                    anchor = slots[index].nodes.last
                } else if slots[index].nodes.count == 1 {
                    // The translation moved an object before text that came first: move it along.
                    let node = slots[index].nodes[0]
                    node.detach()
                    insertAfterAnchor(node)
                }
            }
        }

        for (i, slot) in slots.enumerated() where slot.isText && !used[i] {
            var parent = slot.run.parent as? XMLElement
            slot.run.detach()
            // An emptied hyperlink would be invisible but still clickable in some viewers.
            while let container = parent, container !== paragraph, dialect.removableWhenEmpty.contains(container.qname),
                  container.childElements.isEmpty {
                parent = container.parent as? XMLElement
                container.detach()
            }
        }
    }

    /// Text width in "half-em" units: CJK and other full-width characters count twice. Used to judge whether text grew.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
            return width + (wide ? 2 : 1)
        }
    }

    /// Key of the run properties: their XML without the listed attributes and child elements.
    static func propertiesKey(_ properties: XMLElement?, dropElements: Set<String>, dropAttributes: Set<String>) -> String {
        guard let properties else { return "" }
        func describe(_ element: XMLElement) -> String? {
            let name = element.localName ?? element.name ?? ""
            if element !== properties && dropElements.contains(name) {
                return nil
            }
            let attributes = (element.attributes ?? [])
                .filter { !dropAttributes.contains($0.localName ?? $0.name ?? "") }
                .map { " \($0.localName ?? $0.name ?? "")=\($0.stringValue ?? "")" }
                .sorted()
            let children = element.childElements.compactMap(describe)
            if element === properties && attributes.isEmpty && children.isEmpty {
                return "" // empty properties look like none
            }
            return "<" + name + attributes.joined() + ">" + children.joined() + "</>"
        }
        return describe(properties) ?? ""
    }
}
