import AppKit
import QingYiCore
import SwiftUI

struct LiveView: View {
    @ObservedObject var model: LiveViewModel
    @EnvironmentObject var loc: Loc
    var window: () -> NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let banner = model.banner {
                bannerView(banner)
            }
            LiveTranscriptList(model: model)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 0, trailing: 18))
            footer
        }
        .background(Palette.window)
        .frame(minWidth: 600, minHeight: 420)
        .onAppear { model.refreshMicrophones() }
    }

    // ---------------- sources, languages, controls ----------------

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $model.audioSource) {
                    Text(L("麦克风", "Microphone")).tag(LiveSettings.sourceMicrophone)
                    Text(L("电脑播放的声音", "Mac sound")).tag(LiveSettings.sourceSystem)
                    Text(L("麦克风 + 电脑声音", "Microphone + Mac sound")).tag(LiveSettings.sourceBoth)
                }
                .labelsHidden().frame(width: 170).help(L("音源", "Audio source"))
                if model.usesMicrophone {
                    Picker("", selection: $model.microphoneId) {
                        Text(L("默认麦克风（跟随系统）", "Default microphone")).tag("")
                        ForEach(model.microphones, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden().frame(width: 220).help(L("麦克风", "Microphone"))
                }
                Spacer(minLength: 12)
                Picker("", selection: $model.sourceLanguage) {
                    Text(L("自动检测（中文 / 英文）", "Detect (Chinese / English)")).tag(Languages.autoCode)
                    Divider()
                    ForEach(Languages.all) { language in
                        Text(language.localName).tag(language.code)
                    }
                }
                .labelsHidden().frame(width: 180).help(L("说话的语言", "Spoken language")).disabled(model.state == .preparing || model.state == .downloading)
                Image(systemName: "arrow.right").font(.system(size: 12)).foregroundColor(Palette.textTertiary)
                Picker("", selection: $model.targetLanguage) {
                    ForEach(Languages.all) { language in
                        Text(language.localName).tag(language.code)
                    }
                }
                .labelsHidden().frame(width: 140).help(L("译成", "Translate into"))
            }
            HStack(spacing: 8) {
                Button(model.state == .paused ? L("继续", "Resume") : L("开始", "Start")) { model.startOrResume() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.state != .idle && model.state != .paused)
                    .opacity(model.state != .idle && model.state != .paused ? 0.5 : 1)
                Button(L("暂停", "Pause")) { model.pause() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.state != .running)
                    .opacity(model.state != .running ? 0.5 : 1)
                Button(L("停止", "Stop")) { model.stop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.state == .idle)
                    .opacity(model.state == .idle ? 0.5 : 1)
                Text(model.statusText).font(.system(size: 12)).foregroundColor(Palette.textTertiary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                if model.usesMicrophone {
                    LevelMeter(symbol: "mic", level: model.micLevel).help(L("麦克风音量", "Microphone level"))
                }
                if model.usesSystemAudio {
                    LevelMeter(symbol: "speaker.wave.2", level: model.systemLevel).help(L("电脑声音音量", "Mac sound level")).padding(.leading, 6)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func bannerView(_ banner: LiveViewModel.Banner) -> some View {
        let isError: Bool
        switch banner.kind {
        case .info, .modelDownload: isError = false
        default: isError = true
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(banner.text()).font(.system(size: 13)).foregroundColor(isError ? Palette.errorText : Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = banner.progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 0)
            if case .permission(let kind) = banner.kind {
                Button(L("重置权限", "Reset permission")) { model.resetPermission(kind) }
                    .buttonStyle(LinkButtonStyle())
                    .help(L("清除 macOS 记住的授权，下次开始时会重新询问（更新轻译后授权失效时有用）",
                            "Clears what macOS remembers, so it asks again next time (useful when an update invalidated the permission)"))
            }
            if banner.progress == nil {
                Button(bannerButtonTitle(banner.kind)) { model.bannerPrimaryAction() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            if banner.kind != .info && banner.progress == nil {
                IconButton(symbol: "xmark", help: L("关闭", "Dismiss"), size: 24, fontSize: 11) { model.dismissBanner() }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(isError ? Palette.errorSoft : Palette.accentSoft))
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 0, trailing: 18))
    }

    private func bannerButtonTitle(_ kind: LiveViewModel.BannerKind) -> String {
        switch kind {
        case .permission: return L("打开系统设置", "Open System Settings")
        case .dictation: return L("打开听写设置", "Open Dictation settings")
        case .settings: return L("打开设置", "Open settings")
        case .modelDownload: return L("下载", "Download")
        case .info, .error: return L("知道了", "OK")
        }
    }

    // ---------------- options and export ----------------

    private var footer: some View {
        HStack(spacing: 20) {
            Toggle(isOn: $model.translatePartials) {
                Text(L("临时结果也预翻译", "Translate partial results too")).font(.system(size: 13))
            }
            .toggleStyle(.switch).controlSize(.small)
            .help(L("说话过程中也翻译还在变化的文字（灰色），会多用一些请求", "Also translate the text while it is still changing (grey); uses more requests"))
            Toggle(isOn: $model.showCaptions) {
                Text(L("悬浮字幕", "Floating captions")).font(.system(size: 13))
            }
            .toggleStyle(.switch).controlSize(.small)
            Spacer()
            Menu {
                Section(L("文本", "Text")) {
                    Button(L("TXT · 原文和译文", "TXT · original and translation")) { model.export(format: .text, content: .bilingual, window: window()) }
                    Button(L("TXT · 原文", "TXT · original")) { model.export(format: .text, content: .original, window: window()) }
                    Button(L("TXT · 译文", "TXT · translation")) { model.export(format: .text, content: .translation, window: window()) }
                }
                Section(L("字幕", "Subtitles")) {
                    Button(L("SRT · 双语", "SRT · bilingual")) { model.export(format: .srt, content: .bilingual, window: window()) }
                    Button(L("SRT · 原文", "SRT · original")) { model.export(format: .srt, content: .original, window: window()) }
                    Button(L("SRT · 译文", "SRT · translation")) { model.export(format: .srt, content: .translation, window: window()) }
                }
            } label: {
                Text(L("导出…", "Export…")).font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(L("清空", "Clear")) { model.clear(window: window()) }.buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 12, trailing: 18))
    }
}

/// A small loudness bar with an icon.
struct LevelMeter: View {
    let symbol: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(Palette.textSecondary).frame(width: 16)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(Palette.accent).frame(width: 70 * CGFloat(min(1, max(0, level))))
            }
            .frame(width: 70, height: 4)
            .animation(.linear(duration: 0.08), value: level)
        }
    }
}

// MARK: - Transcript

private struct ContentMetrics: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
}

private struct ContentMetricsKey: PreferenceKey {
    static let defaultValue = ContentMetrics()
    static func reduce(value: inout ContentMetrics, nextValue: () -> ContentMetrics) { value = nextValue() }
}

/// The lines, following new ones while the view is at the bottom; scrolling up stops following until
/// "Jump to latest" (or scrolling back down).
struct LiveTranscriptList: View {
    @ObservedObject var model: LiveViewModel
    @State private var following = true
    @State private var viewport: CGFloat = 0
    @State private var lastHeight: CGFloat = 0
    private let bottom = "bottom"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.transcript.lines) { line in
                            LiveLineRow(line: line, model: model)
                        }
                        Color.clear.frame(height: 1).id(bottom)
                    }
                    .padding(.vertical, 6)
                    .background(GeometryReader { inner in
                        Color.clear.preference(key: ContentMetricsKey.self,
                                               value: ContentMetrics(top: inner.frame(in: .named("liveScroll")).minY, height: inner.size.height))
                    })
                }
                .coordinateSpace(name: "liveScroll")
                .onPreferenceChange(ContentMetricsKey.self) { metrics in
                    // Only a scroll by the user (same content height, new position) changes whether to follow.
                    if abs(metrics.height - lastHeight) < 1 {
                        following = metrics.top + metrics.height - outer.size.height < 40
                    }
                    lastHeight = metrics.height
                }
                .onChange(of: model.transcript.lines) { _ in
                    if following {
                        proxy.scrollTo(bottom, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !following && !model.transcript.lines.isEmpty {
                        Button(L("↓ 回到最新", "↓ Jump to latest")) {
                            following = true
                            proxy.scrollTo(bottom, anchor: .bottom)
                        }
                        .buttonStyle(PillButtonStyle())
                        .padding(.bottom, 14)
                    }
                }
                .overlay {
                    if model.transcript.lines.isEmpty {
                        Text(L("点击“开始”，然后说话或播放视频、网课、会议，原文和译文会实时出现在这里。",
                               "Click Start, then speak or play a video, a lecture or a meeting. The original and its translation appear here as they are spoken."))
                            .font(.system(size: 14)).foregroundColor(Palette.textTertiary).multilineTextAlignment(.center)
                            .padding(.horizontal, 40).allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

struct LiveLineRow: View {
    let line: TranscriptLine
    let model: LiveViewModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.timeText).font(.system(size: 12).monospacedDigit()).foregroundColor(Palette.textTertiary)
                .frame(width: 58, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text).font(.system(size: 14)).italic(!line.isFinal)
                    .foregroundColor(line.isFinal ? Palette.textSecondary : Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !line.translation.isEmpty {
                    Text(line.translation).font(.system(size: 15))
                        .foregroundColor(line.translationIsDraft ? Palette.textTertiary : Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if line.isTranslating {
                    Text(L("正在翻译…", "Translating…")).font(.system(size: 13)).foregroundColor(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
        .background(hovering ? Palette.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("复制原文", "Copy original")) { model.copy(line, original: true, translation: false) }
            Button(L("复制译文", "Copy translation")) { model.copy(line, original: false, translation: true) }
            Button(L("复制原文和译文", "Copy both")) { model.copy(line, original: true, translation: true) }
        }
    }
}

// MARK: - Floating captions

@MainActor
final class CaptionModel: ObservableObject {
    @Published var previous: TranscriptLine?
    @Published var current: TranscriptLine?
    @Published var fontSize: Double

    init(fontSize: Double) {
        self.fontSize = fontSize
    }
}

struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    var close: () -> Void
    var changeSize: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                if let previous = model.previous {
                    caption(previous, sourceSize: 0.7, translationSize: 0.8, opacity: 0.6)
                        .padding(.bottom, model.current == nil ? 0 : 8)
                }
                if let current = model.current {
                    caption(current, sourceSize: 0.8, translationSize: 1, opacity: 0.75)
                }
                if model.previous == nil && model.current == nil {
                    Text(L("悬浮字幕：开始实时转录后，最近的原文和译文会显示在这里", "Floating captions: the latest sentences and translations appear here"))
                        .font(.system(size: model.fontSize * 0.7)).foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 34)
            if hovering {
                VStack(spacing: 2) {
                    captionButton("xmark", L("关闭悬浮字幕", "Close captions"), close)
                    captionButton("plus", L("放大字号", "Larger text")) { changeSize(2) }
                    captionButton("minus", L("缩小字号", "Smaller text")) { changeSize(-2) }
                }
                .padding(.top, -4)
                .padding(.trailing, -4)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
        .onHover { hovering = $0 }
    }

    private func caption(_ line: TranscriptLine, sourceSize: Double, translationSize: Double, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.text).font(.system(size: model.fontSize * sourceSize)).foregroundColor(.white.opacity(opacity))
                .fixedSize(horizontal: false, vertical: true)
            if !line.translation.isEmpty {
                Text(line.translation).font(.system(size: model.fontSize * translationSize, weight: translationSize >= 1 ? .semibold : .regular))
                    .foregroundColor(.white.opacity(line.translationIsDraft ? 0.6 : 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func captionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A borderless, translucent panel that floats above other apps (also over full-screen videos) without taking focus.
final class CaptionPanel: NSPanel {
    let model: CaptionModel
    private let hosting: NSHostingView<CaptionView>

    init(model: CaptionModel, close: @escaping () -> Void, changeSize: @escaping (Double) -> Void) {
        self.model = model
        hosting = NSHostingView(rootView: CaptionView(model: model, close: close, changeSize: changeSize))
        let width = min(820, (NSScreen.main?.visibleFrame.width ?? 900) - 80)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        contentView = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keeps the bottom edge where it is and grows upwards when a longer sentence needs more lines.
    func fitHeight() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let height = hosting.fittingSize.height
            guard height > 0, abs(height - frame.height) > 0.5 else { return }
            var frame = self.frame
            frame.size.height = height
            setFrame(frame, display: true)
        }
    }

    /// Default spot: centered near the bottom of the screen.
    func placeAtBottom() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.minY + 90))
    }
}
