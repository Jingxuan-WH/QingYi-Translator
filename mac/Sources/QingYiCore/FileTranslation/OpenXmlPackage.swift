import Foundation
import ZIPFoundation

/// A namespace-qualified XML name, independent of the prefix a file happens to use.
struct QName: Hashable {
    let ns: String
    let local: String

    init(_ ns: String, _ local: String) {
        self.ns = ns
        self.local = local
    }
}

extension XMLElement {
    var childElements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    /// The element's namespace URI, resolved through its prefix when the parser didn't record it.
    var namespaceURI: String {
        if let uri, !uri.isEmpty {
            return uri
        }
        return resolveNamespace(forName: name ?? "")?.stringValue ?? ""
    }

    var qname: QName { QName(namespaceURI, localName ?? name ?? "") }

    func isNamed(_ name: QName) -> Bool { (localName ?? self.name) == name.local && namespaceURI == name.ns }

    func child(_ name: QName) -> XMLElement? { childElements.first { $0.isNamed(name) } }

    func children(_ name: QName) -> [XMLElement] { childElements.filter { $0.isNamed(name) } }

    /// All descendants with the name, in document order.
    func descendants(_ name: QName) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ element: XMLElement) {
            for child in element.childElements {
                if child.isNamed(name) {
                    result.append(child)
                }
                walk(child)
            }
        }
        walk(self)
        return result
    }

    func ancestors(_ name: QName) -> [XMLElement] {
        var result: [XMLElement] = []
        var node = parent as? XMLElement
        while let element = node {
            if element.isNamed(name) {
                result.append(element)
            }
            node = element.parent as? XMLElement
        }
        return result
    }

    func attributeValue(_ local: String, ns: String? = nil) -> String? {
        if let ns {
            return attribute(forLocalName: local, uri: ns)?.stringValue
        }
        return attribute(forName: local)?.stringValue
            ?? (attributes ?? []).first { $0.localName == local }?.stringValue
    }

    func setAttributeValue(_ name: String, _ value: String?) {
        removeAttribute(forName: name)
        if let value, let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            addAttribute(attribute)
        }
    }

    func insertBefore(_ node: XMLNode) {
        guard let parent = parent as? XMLElement else { return }
        parent.insertChild(node, at: index)
    }

    func insertAfter(_ node: XMLNode) {
        guard let parent = parent as? XMLElement else { return }
        parent.insertChild(node, at: index + 1)
    }

    func deepCopy() -> XMLElement { copy() as! XMLElement }
}

/// The zip container of a .docx/.pptx/.xlsx. Parts are found through [Content_Types].xml; every other entry
/// (images, styles, relationships…) is copied to the output byte for byte.
final class OpenXmlPackage {
    private static let contentTypesNs = "http://schemas.openxmlformats.org/package/2006/content-types"

    private var entries: [(name: String, date: Date, data: Data)] = []
    private var contentTypes: [String: String] = [:]
    private var changed: [String: XMLDocument] = [:]

    init(url: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            // Password-protected Office files are not zip archives at all.
            throw DocumentError(L("文件已加密或已损坏，无法打开。如果设置了打开密码，请先在 Office 中取消密码再翻译。",
                                  "The file is encrypted or damaged. If it has a password, remove it in Office first."))
        }
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            entries.append((entry.path, Date(), data))
        }
        try readContentTypes()
    }

    private func readContentTypes() throws {
        guard let types = entries.first(where: { $0.name.lowercased() == "[content_types].xml" }),
              let document = try? XMLDocument(data: types.data), let root = document.rootElement() else {
            throw DocumentError(L("不是有效的 Office 文档。", "This isn’t a valid Office document."))
        }
        var defaults: [String: String] = [:]
        for element in root.children(QName(OpenXmlPackage.contentTypesNs, "Default")) {
            defaults[(element.attributeValue("Extension") ?? "").lowercased()] = element.attributeValue("ContentType") ?? ""
        }
        for entry in entries {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if let type = defaults[ext] {
                contentTypes[entry.name.lowercased()] = type
            }
        }
        for element in root.children(QName(OpenXmlPackage.contentTypesNs, "Override")) {
            var name = element.attributeValue("PartName") ?? ""
            while name.hasPrefix("/") {
                name.removeFirst()
            }
            contentTypes[(name.removingPercentEncoding ?? name).lowercased()] = element.attributeValue("ContentType") ?? ""
        }
    }

    /// Part names with one of the content types, in the order of the types and then in natural order (slide2 before slide10).
    func parts(ofType types: String...) -> [String] {
        var result: [String] = []
        for type in types {
            result += entries.map(\.name)
                .filter { contentTypes[$0.lowercased()]?.lowercased() == type.lowercased() }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return result
    }

    func load(_ part: String) throws -> XMLDocument {
        if let document = changed[part] {
            return document
        }
        guard let entry = entries.first(where: { $0.name == part }) else {
            throw DocumentError(L("文档缺少 \(part)。", "The document has no \(part)."))
        }
        let document = try XMLDocument(data: entry.data, options: [.nodePreserveWhitespace])
        changed[part] = document
        return document
    }

    func save(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for entry in entries {
            var data = entry.data
            if let document = changed[entry.name] {
                data = document.xmlData(options: [.nodeCompactEmptyElement])
            }
            let bytes = data
            try archive.addEntry(with: entry.name, type: .file, uncompressedSize: Int64(bytes.count), modificationDate: entry.date,
                                 compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}
