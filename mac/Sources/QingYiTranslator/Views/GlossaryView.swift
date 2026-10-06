import AppKit
import Combine
import QingYiCore
import SwiftUI

/// One editable line of the glossary.
@MainActor
final class GlossaryRow: ObservableObject, Identifiable {
    let id = UUID()
    @Published var source: String { didSet { if source != oldValue { flagged = false } } }
    @Published var target: String { didSet { if target != oldValue { flagged = false } } }
    /// Marked after a save attempt when only one side is filled in.
    @Published var flagged = false

    init(source: String = "", target: String = "") {
        self.source = source
        self.target = target
    }

    var isBlank: Bool { source.trimmingCharacters(in: .whitespaces).isEmpty && target.trimmingCharacters(in: .whitespaces).isEmpty }
    var isComplete: Bool { !source.trimmingCharacters(in: .whitespaces).isEmpty && !target.trimmingCharacters(in: .whitespaces).isEmpty }
    var isIncomplete: Bool { !isBlank && !isComplete }
}

enum GlossaryFocus: Hashable {
    case source(UUID)
    case target(UUID)

    var rowId: UUID {
        switch self {
        case .source(let id), .target(let id): return id
        }
    }
}

@MainActor
final class GlossaryViewModel: ObservableObject {
    @Published private(set) var rows: [GlossaryRow] = []
    @Published var search = ""
    @Published var enabled: Bool
    @Published private(set) var message = ""
    @Published private(set) var messageColor = Palette.textSecondary
    @Published var focusRequest: GlossaryFocus?
    var lastFocus: GlossaryFocus?

    /// The entries to save, once `save()` returned true.
    private(set) var entries: [GlossaryEntry] = []
    private(set) var saved = false

    private var rowSubscriptions: [UUID: AnyCancellable] = [:]
    private var showingIncompleteWarning = false

    init(glossary: Glossary, enabled: Bool) {
        self.enabled = enabled
        for entry in glossary.entries {
            add(GlossaryRow(source: entry.source, target: entry.target))
        }
        ensureBlankRowAtEnd()
    }

    var countText: String {
        let count = rows.filter(\.isComplete).count
        return L("共 \(count) 条", count == 1 ? "1 term" : "\(count) terms")
    }

    var visibleRows: [GlossaryRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return rows
        }
        return rows.filter {
            $0.isBlank || $0.source.range(of: query, options: .caseInsensitive) != nil || $0.target.range(of: query, options: .caseInsensitive) != nil
        }
    }

    private func add(_ row: GlossaryRow, at index: Int? = nil) {
        rowSubscriptions[row.id] = row.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rowChanged() }
        }
        if let index, index <= rows.count {
            rows.insert(row, at: index)
        } else {
            rows.append(row)
        }
    }

    private func remove(_ row: GlossaryRow) {
        rowSubscriptions.removeValue(forKey: row.id)
        rows.removeAll { $0.id == row.id }
    }

    private func rowChanged() {
        ensureBlankRowAtEnd()
        if showingIncompleteWarning && !rows.contains(where: \.flagged) {
            setMessage("")
        }
        objectWillChange.send()
    }

    /// There is always one empty line at the bottom to type a new term into.
    private func ensureBlankRowAtEnd() {
        if rows.isEmpty || !rows[rows.count - 1].isBlank {
            add(GlossaryRow())
        }
    }

    private func setMessage(_ text: String, _ color: Color = Palette.textSecondary) {
        message = text
        messageColor = color
        showingIncompleteWarning = false
    }

    // ---------------- editing ----------------

    func delete(_ row: GlossaryRow) {
        remove(row)
        ensureBlankRowAtEnd()
        if showingIncompleteWarning && !rows.contains(where: \.flagged) {
            setMessage("")
        }
    }

    /// Return moves to the next line (like a spreadsheet); on the last line it starts a new term.
    func moveToNextRow(from focus: GlossaryFocus) {
        ensureBlankRowAtEnd()
        guard let index = rows.firstIndex(where: { $0.id == focus.rowId }), index + 1 < rows.count else { return }
        let next = rows[index + 1]
        if case .target = focus, !next.isBlank {
            focusRequest = .target(next.id)
        } else {
            focusRequest = .source(next.id)
        }
    }

    func focusLastRow() {
        if let last = rows.last {
            focusRequest = .source(last.id)
        }
    }

    /// Pasting several lines (or two cells copied from Excel) adds one term per line. False when the clipboard is a single value.
    func pasteFromClipboard(force: Bool) -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        if !force && text.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\t")) == nil {
            return false
        }
        let entries = Glossary.parse(text)
        if entries.isEmpty {
            if force {
                setMessage(L("剪贴板里没有找到术语。每行一条，两列用逗号、Tab 或 = 分开。", "No terms found on the clipboard. Put one term per line, with the two columns separated by a comma, tab or ="), Palette.error)
            }
            return false
        }
        insert(entries, at: lastFocus.flatMap { focus in rows.firstIndex { $0.id == focus.rowId } })
        let count = entries.count
        setMessage(L("已粘贴 \(count) 条术语", count == 1 ? "Pasted 1 term" : "Pasted \(count) terms"))
        return true
    }

    private func insert(_ entries: [GlossaryEntry], at index: Int?) {
        var position: Int
        if let index, index < rows.count {
            let row = rows[index]
            if row.isBlank {
                remove(row)
                position = index
            } else {
                position = index + 1
            }
        } else {
            position = rows.count
            if let last = rows.last, last.isBlank {
                remove(last)
                position = rows.count
            }
        }
        for entry in entries {
            add(GlossaryRow(source: entry.source, target: entry.target), at: position)
            position += 1
        }
        ensureBlankRowAtEnd()
    }

    // ---------------- import / export ----------------

    func importFile(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = L("导入术语表", "Import glossary")
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try Glossary.readFile(url)
            if entries.isEmpty {
                setMessage(L("文件里没有找到术语。每行一条，两列用逗号、Tab 或 = 分开。",
                             "No terms found. Put one term per line, with the two columns separated by a comma, tab or =."), Palette.error)
                return
            }
            insert(entries, at: nil)
            let count = entries.count
            setMessage(L("已导入 \(count) 条术语，保存后生效", count == 1 ? "Imported 1 term. Save to apply" : "Imported \(count) terms. Save to apply"))
        } catch {
            setMessage(L("无法读取文件：\(error.localizedDescription)", "Could not read the file: \(error.localizedDescription)"), Palette.error)
        }
    }

    func exportFile(from window: NSWindow?) {
        let entries = Glossary.clean(rows.map { GlossaryEntry(source: $0.source, target: $0.target) })
        if entries.isEmpty {
            setMessage(L("还没有可以导出的术语", "There are no terms to export yet"), Palette.error)
            return
        }
        let panel = NSSavePanel()
        panel.title = L("导出术语表", "Export glossary")
        panel.nameFieldStringValue = L("术语表.csv", "glossary.csv")
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Glossary.writeCsv(to: url, entries: entries)
            let count = entries.count
            setMessage(L("已导出 \(count) 条术语", count == 1 ? "Exported 1 term" : "Exported \(count) terms"), Palette.success)
        } catch {
            setMessage(L("无法保存文件：\(error.localizedDescription)", "Could not save the file: \(error.localizedDescription)"), Palette.error)
        }
    }

    // ---------------- save ----------------

    func save() -> Bool {
        let incomplete = rows.filter(\.isIncomplete)
        if !incomplete.isEmpty {
            for row in incomplete {
                row.flagged = true
            }
            search = ""
            let count = incomplete.count
            setMessage(L("有 \(count) 条术语只填了一边，请补全或删除", count == 1 ? "1 term is missing one side. Complete or delete it" : "\(count) terms are missing one side. Complete or delete them"), Palette.error)
            showingIncompleteWarning = true
            let first = incomplete[0]
            focusRequest = first.source.trimmingCharacters(in: .whitespaces).isEmpty ? .source(first.id) : .target(first.id)
            return false
        }
        entries = Glossary.clean(rows.map { GlossaryEntry(source: $0.source, target: $0.target) })
        saved = true
        return true
    }
}

struct GlossaryView: View {
    @ObservedObject var model: GlossaryViewModel
    @EnvironmentObject var loc: Loc
    var window: () -> NSWindow?
    var close: () -> Void

    @FocusState private var focus: GlossaryFocus?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("术语表", "Glossary")).font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.textPrimary)
                Text(model.countText).font(.system(size: 12)).foregroundColor(Palette.textTertiary).padding(.leading, 10)
                Spacer()
                Toggle(isOn: $model.enabled) { Text(L("启用术语表", "Use glossary")).font(.system(size: 13)) }
                    .toggleStyle(.switch).controlSize(.small)
            }
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 8, trailing: 20))
            HStack(spacing: 8) {
                SearchField(text: $model.search, placeholder: L("搜索术语", "Search terms"))
                Button(L("粘贴", "Paste")) { _ = model.pasteFromClipboard(force: true) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    .help(L("从剪贴板粘贴多条术语（每行一条，或 Excel 里复制的两列）", "Paste several terms from the clipboard (one per line, or two columns copied from Excel)"))
                Button(L("导入…", "Import…")) { model.importFile(from: window()) }.buttonStyle(SecondaryButtonStyle(compact: true))
                Button(L("导出…", "Export…")) { model.exportFile(from: window()) }.buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            HStack(spacing: 8) {
                Text(L("术语", "Term")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("译法", "Translation")).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 26)
            }
            .font(.system(size: 12)).foregroundColor(Palette.textTertiary)
            .padding(.horizontal, 20).padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleRows) { row in
                        GlossaryRowView(row: row, focus: $focus, onNext: { model.moveToNextRow(from: $0) }, onDelete: { model.delete(row) })
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }
            HStack {
                Text(model.message).font(.system(size: 12)).foregroundColor(model.messageColor).lineLimit(2)
                Spacer()
                Button(L("取消", "Cancel")) { close() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) { if model.save() { close() } }.buttonStyle(PrimaryButtonStyle()).padding(.leading, 10)
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            .background(Palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .background(Palette.window)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { model.focusLastRow() }
        .onChange(of: model.focusRequest) { request in
            if let request {
                focus = request
                model.focusRequest = nil
            }
        }
        .onChange(of: focus) { model.lastFocus = $0 ?? model.lastFocus }
    }
}

struct GlossaryRowView: View {
    @ObservedObject var row: GlossaryRow
    var focus: FocusState<GlossaryFocus?>.Binding
    var onNext: (GlossaryFocus) -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            cell($row.source, .source(row.id))
            cell($row.target, .target(row.id))
            IconButton(symbol: "trash", help: L("删除", "Delete"), size: 26, fontSize: 12) { onDelete() }
                .opacity(hovering && !row.isBlank ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }

    private func cell(_ text: Binding<String>, _ field: GlossaryFocus) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(row.flagged ? Palette.error : Palette.inputLine, lineWidth: 1))
            .focused(focus, equals: field)
            .onSubmit { onNext(field) }
    }
}
