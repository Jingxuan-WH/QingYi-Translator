import Foundation

/// A piece of a paragraph: text in one of the paragraph's formats, or an object that must stay as it is.
/// `style` is the index of the format among the paragraph's formats (text pieces); `atom` the index of the
/// object among the paragraph's objects (formulas, images, footnote marks…), -1 for text.
public struct InlinePiece: Equatable {
    public var text: String
    public var style: Int
    public var atom: Int

    public var isAtom: Bool { atom >= 0 }

    public static func of(_ text: String, _ style: Int) -> InlinePiece { InlinePiece(text: text, style: style, atom: -1) }

    public static func object(_ atom: Int, _ text: String = "") -> InlinePiece { InlinePiece(text: text, style: -1, atom: atom) }
}

/// A paragraph sent to the model with its formatting as inline tags: text in a format other than the paragraph's
/// main one is wrapped as <1>…</1> (one number per format), and objects such as formulas or images become <2/>.
/// The model translates the text and keeps the tags, so the formatting can be put back.
public final class TaggedText {
    static let tagPattern = try! NSRegularExpression(pattern: "<(/?)(\\d{1,3})(\\s*/)?>")

    private var styleOfTag: [Int: Int] = [:]
    private var atomOfTag: [Int: Int] = [:]

    /// What is sent for translation.
    public private(set) var text = ""

    /// The paragraph's main format; untagged text in the translation gets it.
    public let baseStyle: Int

    public var hasTags: Bool { !styleOfTag.isEmpty || !atomOfTag.isEmpty }

    private init(baseStyle: Int) {
        self.baseStyle = baseStyle
    }

    /// Builds the tagged text. The format with the most characters stays untagged, which keeps the tags few.
    public static func build(_ pieces: [InlinePiece]) -> TaggedText {
        var lengths: [Int: Int] = [:]
        for piece in pieces where !piece.isAtom {
            lengths[piece.style, default: 0] += piece.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        }
        var baseStyle = 0
        var best = -1
        // Ties go to the format that comes first.
        for piece in pieces where !piece.isAtom && lengths[piece.style, default: 0] > best {
            best = lengths[piece.style, default: 0]
            baseStyle = piece.style
        }

        let result = TaggedText(baseStyle: baseStyle)
        var tagOfStyle: [Int: Int] = [:]
        var tagOfAtom: [Int: Int] = [:]
        var text = ""
        var nextTag = 1
        for piece in pieces {
            if piece.isAtom {
                let tag: Int
                if let existing = tagOfAtom[piece.atom] {
                    tag = existing
                } else {
                    tag = nextTag
                    nextTag += 1
                    tagOfAtom[piece.atom] = tag
                    result.atomOfTag[tag] = piece.atom
                }
                text += "<\(tag)/>"
            } else if piece.style == baseStyle || piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Whitespace in another format isn't worth a tag.
                text += piece.text
            } else {
                let tag: Int
                if let existing = tagOfStyle[piece.style] {
                    tag = existing
                } else {
                    tag = nextTag
                    nextTag += 1
                    tagOfStyle[piece.style] = tag
                    result.styleOfTag[tag] = piece.style
                }
                // Spaces stay outside the tags, so the model doesn't drop or move them.
                let value = piece.text
                let lead = String(value.prefix(while: { $0.isWhitespace }))
                let trail = String(value.reversed().prefix(while: { $0.isWhitespace }).reversed())
                let core = value.trimmingCharacters(in: .whitespacesAndNewlines)
                text += lead + "<\(tag)>" + core + "</\(tag)>" + trail
            }
        }
        result.text = text
        return result
    }

    /// Reads a translation back into pieces. Unknown, unbalanced or misplaced tags are dropped rather than
    /// failing: the text then simply gets the main format. Adjacent text in the same format is merged.
    public func parse(_ translation: String) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        var open: [Int] = [] // styles of the tags currently open, innermost last
        let source = translation as NSString
        var position = 0

        func addText(_ text: String) {
            guard !text.isEmpty else { return }
            let style = open.last ?? baseStyle
            if let last = pieces.last, !last.isAtom, last.style == style {
                pieces[pieces.count - 1].text += text
            } else {
                pieces.append(.of(text, style))
            }
        }

        for match in TaggedText.tagPattern.matches(in: translation, range: NSRange(location: 0, length: source.length)) {
            let tag = Int(source.substring(with: match.range(at: 2))) ?? -1
            let closing = match.range(at: 1).length > 0
            let selfClosing = match.range(at: 3).location != NSNotFound
            guard styleOfTag[tag] != nil || atomOfTag[tag] != nil else {
                continue // e.g. "<5>" that was part of the text itself: leave it in place
            }
            addText(source.substring(with: NSRange(location: position, length: match.range.location - position)))
            position = match.range.location + match.range.length
            if let atom = atomOfTag[tag] {
                if !closing {
                    pieces.append(.object(atom))
                }
            } else if !selfClosing, let style = styleOfTag[tag] {
                if !closing {
                    open.append(style)
                } else if let index = open.lastIndex(of: style) {
                    open.removeSubrange(index...)
                }
            }
        }
        addText(source.substring(from: position))
        return pieces
    }

    /// The text without any tags, e.g. for the domain sample or for formats that can't hold formatting.
    public static func stripTags(_ text: String) -> String {
        tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }
}
