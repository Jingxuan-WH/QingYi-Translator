import AppKit
import QingYiCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model: MainViewModel
    @EnvironmentObject var loc: Loc
    var window: () -> NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                VStack(spacing: 0) {
                    translatorCard.padding(EdgeInsets(top: 16, leading: 20, bottom: 6, trailing: 20))
                    statusBar
                }
                if model.isHistoryOpen {
                    HistoryDrawer(model: model, window: window)
                }
            }
        }
        .background(Palette.window)
        .frame(minWidth: 640, minHeight: 420)
    }

    // ---------------- header ----------------

    private var header: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.accent)
                .frame(width: 28, height: 28)
                .overlay(Text("译").font(.system(size: 15, weight: .bold)).foregroundColor(.white))
            Text(L("轻译", "QingYi"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Palette.textPrimary)
                .padding(.leading, 10)
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 14, weight: .semibold))
                Text(L("翻译文本", "Translate text")).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(Palette.accentText)
            .frame(height: 52)
            .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 1).fill(Palette.accentText).frame(height: 2).padding(.horizontal, -2) }
            .padding(.leading, 34)
            Spacer(minLength: 8)
            if let release = model.availableUpdate {
                Button(L("新版本 \(release.versionText)", "Update \(release.versionText)")) { model.showUpdate?(release) }
                    .buttonStyle(PillButtonStyle())
                    .help(L("点击查看更新内容并升级", "See what’s new and update"))
                    .padding(.trailing, 10)
            }
            IconButton(symbol: "clock", help: L("翻译历史 (⌘Y)", "History (⌘Y)"), isOn: model.isHistoryOpen) { model.toggleHistory() }
            IconButton(symbol: "book", help: L("术语表", "Glossary")) { model.openGlossary?() }.padding(.leading, 4)
            IconButton(symbol: model.topmost ? "pin.fill" : "pin", help: model.topmost ? L("取消置顶", "Unpin") : L("窗口置顶", "Keep on top"),
                       isOn: model.topmost) { model.togglePin() }.padding(.leading, 4)
            IconButton(symbol: "gearshape", help: L("设置 (⌘,)", "Settings (⌘,)")) { model.openSettings?() }.padding(.leading, 4)
        }
        .padding(.leading, 78) // leaves room for the traffic lights
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    // ---------------- translator card ----------------

    private var translatorCard: some View {
        VStack(spacing: 0) {
            languageBar.frame(height: 52)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 0) {
                sourcePane
                Rectangle().fill(Palette.line).frame(width: 1)
                outputPane
            }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
        .shadow(color: Palette.shadow, radius: 11, x: 0, y: 2)
    }

    private var languageBar: some View {
        HStack(spacing: 0) {
            HStack { languageMenu(isSource: true).padding(.leading, 10); Spacer() }.frame(maxWidth: .infinity)
            HStack { languageMenu(isSource: false).padding(.leading, 10); Spacer() }.frame(maxWidth: .infinity)
        }
        .overlay(IconButton(symbol: "arrow.left.arrow.right", help: L("交换语言", "Swap languages")) { model.swapLanguages() })
    }

    private func languageMenu(isSource: Bool) -> some View {
        var entries: [MenuEntry] = []
        if isSource {
            entries.append(MenuEntry(L("检测语言", "Detect language"), isSelected: model.source == nil) { model.selectSource(nil) })
            entries.append(.separator)
        }
        for language in Languages.all {
            let selected = isSource ? model.source == language : model.target == language
            entries.append(MenuEntry(language.localName, isSelected: selected) {
                if isSource { model.selectSource(language) } else { model.selectTarget(language) }
            })
        }
        return LanguageMenuButton(title: isSource ? model.sourceLabel : model.target.localName, entries: entries,
                                  accessibilityLabel: isSource ? L("源语言", "Source language") : L("目标语言", "Target language"))
            .fixedSize()
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PaneTextView(text: $model.sourceText, isEditable: true, focusRequest: model.focusRequest,
                             onCommandReturn: { model.translate(force: true) }, onEscape: { escapePressed() })
                if model.sourceText.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("输入或粘贴要翻译的文本", "Type or paste text to translate"))
                            .font(.system(size: 18)).foregroundColor(Palette.textTertiary)
                        if !model.placeholderHint.isEmpty {
                            Text(model.placeholderHint).font(.system(size: 13)).foregroundColor(Palette.textTertiary)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 22, bottom: 0, trailing: 44))
                    .allowsHitTesting(false)
                } else {
                    HStack {
                        Spacer()
                        IconButton(symbol: "xmark", help: L("清空", "Clear"), size: 28, fontSize: 12) { model.clearSource() }
                            .padding(.top, 8).padding(.trailing, 8)
                    }
                }
            }
            HStack {
                Text(model.characterCountText).font(.system(size: 12)).foregroundColor(Palette.textTertiary)
                Spacer()
            }
            .padding(.leading, 22).padding(.trailing, 10)
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PaneTextView(text: Binding(get: { model.outputText }, set: { _ in }), isEditable: false, onEscape: { escapePressed() })
                if model.outputText.isEmpty && !model.isBusy {
                    Text(L("译文", "Translation")).font(.system(size: 18)).foregroundColor(Palette.textTertiary)
                        .padding(EdgeInsets(top: 14, leading: 22, bottom: 0, trailing: 20))
                        .allowsHitTesting(false)
                }
                if model.isBusy {
                    LoadingBar()
                }
            }
            if let error = model.errorMessage {
                errorPanel(error)
            }
            HStack {
                Text(model.statusText).font(.system(size: 12)).foregroundColor(Palette.textTertiary).lineLimit(1).truncationMode(.tail)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: L("整体重新翻译 (⌘↩)", "Retranslate everything (⌘↩)")) { model.translate(force: true) }
                IconButton(symbol: model.copied ? "checkmark" : "doc.on.doc", help: model.copied ? L("已复制", "Copied") : L("复制译文", "Copy translation")) {
                    model.copyTranslation()
                }
                .padding(.leading, 2)
            }
            .padding(.leading, 22).padding(.trailing, 10)
            .frame(height: 44)
        }
        .background(Palette.output)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPanel(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundColor(Palette.error).padding(.top, 2)
            Text(message).font(.system(size: 13)).foregroundColor(Palette.errorText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ErrorText")
            Spacer(minLength: 0)
            if model.errorNeedsSettings {
                Button(L("打开设置", "Open settings")) { model.openSettings?() }.buttonStyle(LinkButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.errorSoft))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var statusBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(model.engineOk ? Palette.success : Palette.warning).frame(width: 7, height: 7)
                Text(model.engineText).font(.system(size: 12)).foregroundColor(Palette.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openSettings?() }
            .help(L("更改翻译服务", "Change translation service"))
            Spacer()
            Text(model.shortcutHint).font(.system(size: 12))
                .foregroundColor(model.shortcutHintIsError ? Palette.error : Palette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
        .frame(height: 36)
    }

    private func escapePressed() {
        if model.isHistoryOpen {
            model.isHistoryOpen = false
        } else {
            model.hideWindow?()
        }
    }
}

struct LoadingBar: View {
    @State private var offset: CGFloat = -140

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.accentText)
                .frame(width: 140, height: 2)
                .offset(x: offset)
                .onAppear {
                    offset = -140
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        offset = max(geometry.size.width, 200)
                    }
                }
        }
        .frame(height: 2)
        .clipped()
    }
}

// ---------------- history drawer ----------------

struct HistoryDrawer: View {
    @ObservedObject var model: MainViewModel
    var window: () -> NSWindow?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Palette.backdrop.contentShape(Rectangle()).onTapGesture { model.isHistoryOpen = false }
            VStack(spacing: 0) {
                HStack {
                    Text(L("翻译历史", "History")).font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.textPrimary)
                    let total = model.history.entries.count
                    if total > 0 {
                        Text(L("共 \(total) 条", total == 1 ? "1 entry" : "\(total) entries"))
                            .font(.system(size: 12)).foregroundColor(Palette.textTertiary).padding(.leading, 10)
                    }
                    Spacer()
                    if total > 0 {
                        Button(L("清空", "Clear all")) { model.clearHistory(window: window()) }.buttonStyle(LinkButtonStyle()).padding(.trailing, 12)
                    }
                    IconButton(symbol: "xmark", help: L("关闭 (Esc)", "Close (Esc)"), size: 28, fontSize: 12) { model.isHistoryOpen = false }
                }
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 6, trailing: 10))
                SearchField(text: $model.historySearch, placeholder: L("搜索原文或译文", "Search source or translation"))
                    .padding(.horizontal, 18).padding(.bottom, 10)
                let entries = model.filteredHistory
                if entries.isEmpty {
                    Spacer()
                    Text(model.historyEmptyText).font(.system(size: 13)).foregroundColor(Palette.textTertiary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                HistoryRow(entry: entry, onRestore: { model.restoreFromHistory(entry) }, onDelete: { model.deleteHistory(entry) })
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
            .shadow(color: Palette.shadow, radius: 14, x: 0, y: 4)
            .padding(EdgeInsets(top: 12, leading: 0, bottom: 14, trailing: 20))
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var onRestore: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(entry.languagePairText).font(.system(size: 11)).foregroundColor(Palette.textSecondary).lineLimit(1)
                    Spacer()
                    Text(entry.timeText).font(.system(size: 11)).foregroundColor(Palette.textTertiary).padding(.leading, 8)
                }
                Text(entry.sourcePreview).font(.system(size: 13)).foregroundColor(Palette.textPrimary).lineLimit(2).padding(.top, 5)
                Text(entry.translationPreview).font(.system(size: 13)).foregroundColor(Palette.textSecondary).lineLimit(2).padding(.top, 3)
            }
            .padding(.trailing, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                IconButton(symbol: "trash", help: L("删除这条记录", "Delete this entry"), size: 26, fontSize: 12) { onDelete() }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 10))
        .background(hovering ? Palette.hover : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onRestore() }
        .onHover { hovering = $0 }
    }
}
